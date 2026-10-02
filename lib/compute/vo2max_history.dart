// ONE-SHOT backfill pass — RETROSPECTIVE VO₂max estimates from stored
// history ("Schätzung aus bisherigen Aktivitäten"). The counterpart of
// strain_backfill.dart: a pass that walks data the raw substrate no longer
// covers and writes an added derived value, once, idempotently.
//
// WHAT IT READS — the per-km `workout_split` rows frozen at finalize
// (CV-01/TS-07) and the `metric_series['rhr']` nightly resting-HR series.
// It does NOT read raw 1 Hz, routes, or anything pruned after 3 days, so
// it works over the FULL stored history, not just the retention window.
//
// WHAT IT WRITES — one `vo2max_history` row per (session, km), carrying the
// estimate or the snake_case abstention reason. Never onto `sessions`:
// the original session values, routes and test assignments are untouched.
//
// WHEN IT RUNS — from the derivation engine's run() tail after the strain
// rescale, INCREMENTALLY: a full pass exactly once per formula version
// (`compute_freshness` payload carries the version), then only sessions
// that have split rows but no history rows yet — a session finalized after
// the first pass is picked up by the next derive. Re-runs are idempotent:
// putVo2maxHistory replaces a session's rows in place, never duplicates.
//
// METHOD — the SAME published submax chain the live estimate uses
// (see docs/VO2MAX.md §2 for sources and limits):
//   1. ACSM walking/running metabolic equation on the split's own pace:
//        walking (<2 m/s): VO2sub = 0.1*v + 1.8*v*grade + 3.5  [v in m/min]
//        running (>=2 m/s): VO2sub = 0.2*v + 0.9*v*grade + 3.5
//   2. Swain & Leutholtz (1997) %HRR ~ %VO2R, extrapolated:
//        VO2max_est = 3.5 + (VO2sub - 3.5) / %HRR
//
// WHAT IS HONEST HERE, AND IS NOT:
//   * A split is a real distance over a real duration with its own average
//     HR — a genuine submaximal bout, not a fabricated input. But it is a
//     FREE-RECORDED activity, not a standardised test protocol: no Åstrand
//     step test, no Cooper 12-min protocol, no treadmill ramp. The result
//     is an ESTIMATE-tier claim of the same grade as the live one, and it
//     is labelled "Schätzung aus bisherigen Aktivitäten" everywhere it
//     shows. No standardised-walk-test protocol (Rockport et al.) is
//     claimed or run: a casual stroll fails the 40 %HRR floor on its own —
//     the band, not a type judgment, decides.
//   * HRmax is an observed ceiling recorded strictly BEFORE the session, or
//     the Tanaka age line with the CURRENT profile age — see
//     [hrMaxForSession]. The session's own peak HR is NEVER an HRmax input.
//   * HRrest is the trailing measured nightly RHR as of the session's date
//     (point-in-time), or the user's manual value. A LATER RHR value is
//     never passed off as the historically available one.

import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';
import '../data/day_label.dart' show dayLabelOf;
import 'profile.dart' show Profile;
import 'vo2max_activity_gate.dart' show vo2maxEligibleActivity;

/// Minimum metres a stored split must cover to count as a FULL kilometre for
/// the retrospective estimate — the same rule as the live pass's `>=999 m`
/// filter. A kilometre binning can land slightly under 1000 m, so this is a
/// technical heuristic tolerance, not a physiological threshold.
const double kVo2maxFullSplitMinMeters = 999.0;

/// Method code stored on every row — the one method this pass implements.
/// See docs/VO2MAX.md for the formula, sources and limits.
const String kVo2maxHistoryMethod = 'acsm_speed_swain_hrr';

/// Formula version — bumped when ANY part of the grading chain changes
/// (coefficients, gates, bout aggregation, anchor policy) so a stored row
/// can always be traced to the exact chain that produced it. v2: bouts of
/// consecutive splits replace per-km grading (the 300 s steady-state gate
/// now applies to the CONTIGUOUS EFFORT, not to each km in isolation).
const String kVo2maxHistoryFormulaVersion = '2';

/// `compute_freshness` key carrying the pass's progress. The payload holds
/// [kVo2maxHistoryFormulaVersion], so a formula bump triggers ONE full
/// re-pass (rows are replaced per session in place, never duplicated) and
/// every later derive runs INCREMENTALLY: only sessions that have split
/// rows but no `vo2max_history` rows yet are walked. The old one-shot
/// `{'done': true}` gate starved the trend on fresh installs — the first
/// derive ran before any workout existed, marked the pass done forever,
/// and no later session was ever backfilled.
const String kVo2maxHistoryFreshnessKey = 'vo2max_history_v2';

/// A split as the historical pass reads it: the frozen `workout_split` row
/// plus the session's own metadata. Value type, not a DB row — the pass is
/// testable without a database.
class Vo2maxHistorySplit {
  final String sessionId;
  final String? sessionType;
  /// Split index (1-based km), from `workout_split.km`.
  final int km;
  /// metres actually covered by this split (>= 999 for a full km).
  final double meters;
  final int durationSec;
  /// The split's own average HR (bpm), frozen at finalize. Null when the
  /// 1 Hz join came back empty — the split exists, its HR does not.
  final double? avgHrBpm;
  /// Net elevation over the split (m), or null when altitude was missing
  /// at either end. Null means "grade unknown", never "flat".
  final double? netElevM;

  const Vo2maxHistorySplit({
    required this.sessionId,
    required this.sessionType,
    required this.km,
    required this.meters,
    required this.durationSec,
    required this.avgHrBpm,
    required this.netElevM,
  });
}

/// Outcome of the historical pass for one split — a value OR a
/// machine-readable snake_case reason, never a 0, never prose.
class Vo2maxHistorySplitResult {
  final String sessionId;
  final int km;
  /// ml/kg/min, UNROUNDED (rounding is a display concern). Null on
  /// abstention.
  final double? vo2max;
  /// Why [vo2max] is null, snake_case storage vocabulary — the prose map
  /// lives with the UI (`vo2maxAbsenceText`), storage stays code.
  final String? absenceReason;

  const Vo2maxHistorySplitResult({
    required this.sessionId,
    required this.km,
    required this.vo2max,
    required this.absenceReason,
  });

  bool get present => vo2max != null;
}

/// Evaluate ONE historical split against the submax chain.
///
/// Deterministic and pure: no DB, no clock, no isolate. Every gate that
/// abstains returns a code, so the pass can bank WHY history produced
/// nothing instead of a silent gap.
Vo2maxHistorySplitResult vo2maxFromHistoricalSplit(
  Vo2maxHistorySplit s, {
  required double restingHrBpm,
  required double hrMaxBpm,
}) {
  Vo2maxHistorySplitResult absent(String reason) =>
      Vo2maxHistorySplitResult(
        sessionId: s.sessionId,
        km: s.km,
        vo2max: null,
        absenceReason: reason,
      );

  if (!vo2maxEligibleActivity(s.sessionType)) {
    return absent('unsupported_activity');
  }
  if (s.avgHrBpm == null) return absent('no_steady_hr_for_split');
  // FULL km only, the same >=999 m rule as the live estimate: a partial
  // trailing km has no fixed distance, so its "speed" is not a real pace
  // and the ACSM equation would be fed a number it never claimed. The
  // stored table DOES carry the partial km (computeSplits emits it), so
  // this gate is what keeps it out of the estimate.
  if (s.durationSec <= 0 ||
      !s.meters.isFinite ||
      s.meters < kVo2maxFullSplitMinMeters) {
    return absent('no_completed_km_split');
  }

  final m = _estimateBout(
    meters: s.meters,
    durationSec: s.durationSec,
    avgHrBpm: s.avgHrBpm!,
    netElevM: s.netElevM,
    restingHrBpm: restingHrBpm,
    hrMaxBpm: hrMaxBpm,
  );
  if (!m.present) return absent('no_qualifying_bout');
  return Vo2maxHistorySplitResult(
    sessionId: s.sessionId,
    km: s.km,
    vo2max: m.value,
    absenceReason: null,
  );
}

/// The submax chain over ONE contiguous bout. Pure, shared by the
/// single-split path above and the concatenated-bout path below, so both
/// grade the same maths.
///
/// THE 300 s BOUT MINIMUM IS ABOUT STEADY-STATE HR, NOT DISTANCE. A runner
/// at 4:30/km covers a km in 270 s — a real submaximal bout the per-split
/// 300 s gate rejected outright (reproduced against the pinned analytics:
/// 270 s -> absent, the same effort over 540 s -> 65.3). The history pass
/// therefore concatenates CONSECUTIVE qualifying splits of one session into
/// one bout and grades the bout, not each km in isolation. Concatenation
/// itself is a TECHNICAL HEURISTIC: it assumes consecutive km splits of one
/// recorded session are one continuous effort — a pause inside the recorded
/// route keeps its time in the split durations, lowering pace and HR alike.
ana.Metric<double> _estimateBout({
  required double meters,
  required int durationSec,
  required double avgHrBpm,
  required double? netElevM,
  required double restingHrBpm,
  required double hrMaxBpm,
}) {
  return ana.vo2maxSubmaxEstimate(
    speedMps: meters / durationSec,
    avgHrBpm: avgHrBpm,
    boutDurationSec: durationSec,
    restingHrBpm: restingHrBpm,
    hrMaxBpm: hrMaxBpm,
    // Null (unknown) grade — never 0, which would read as "flat".
    gradePercent: netElevM == null ? null : netElevM / meters * 100,
  );
}

/// A CONTIGUOUS BOUT of consecutive splits: same session (same sport by
/// construction), strictly consecutive km, every member individually
/// usable (full km, own HR). Graded as one bout — the pace is the bout's
/// own distance/duration (never a mean of per-split paces), the HR is the
/// duration-weighted mean of the member splits' averages, the grade is the
/// net elevation over the whole bout (null when any member lacks it).
Vo2maxHistorySplitResult vo2maxFromHistoricalBout(
  List<Vo2maxHistorySplit> splits, {
  required double restingHrBpm,
  required double hrMaxBpm,
}) {
  assert(splits.isNotEmpty);
  final first = splits.first;
  Vo2maxHistorySplitResult absent(String reason) =>
      Vo2maxHistorySplitResult(
        sessionId: first.sessionId,
        km: first.km,
        vo2max: null,
        absenceReason: reason,
      );
  if (!vo2maxEligibleActivity(first.sessionType)) {
    return absent('unsupported_activity');
  }
  for (final s in splits) {
    if (s.avgHrBpm == null) return absent('no_steady_hr_for_split');
    if (s.durationSec <= 0 ||
        !s.meters.isFinite ||
        s.meters < kVo2maxFullSplitMinMeters) {
      return absent('no_completed_km_split');
    }
  }
  for (var i = 1; i < splits.length; i++) {
    if (splits[i].km != splits[i - 1].km + 1) {
      return absent('no_qualifying_bout');
    }
  }
  var meters = 0.0, elev = 0.0, dur = 0;
  var hrNum = 0.0;
  var hasElev = true;
  for (final s in splits) {
    meters += s.meters;
    dur += s.durationSec;
    hrNum += s.avgHrBpm! * s.durationSec;
    if (s.netElevM == null) {
      hasElev = false;
    } else {
      elev += s.netElevM!;
    }
  }
  final m = _estimateBout(
    meters: meters,
    durationSec: dur,
    avgHrBpm: hrNum / dur,
    netElevM: hasElev ? elev : null,
    restingHrBpm: restingHrBpm,
    hrMaxBpm: hrMaxBpm,
  );
  if (!m.present) return absent('no_qualifying_bout');
  return Vo2maxHistorySplitResult(
    sessionId: first.sessionId,
    km: first.km,
    vo2max: m.value,
    absenceReason: null,
  );
}

/// HRmax (bpm) a HISTORICAL session may be graded against.
///
/// In preference order:
///   1. An observed ceiling recorded strictly BEFORE the session started
///      — real measured evidence, one-sided as it is (see hr_max.dart for
///      why one-sided is still preferred here).
///   2. The Tanaka age line `208 - 0.7*age` with the CURRENT profile age,
///      explicitly an estimate.
///
/// The session's own peak HR is NEVER an HRmax input to this function: the
/// highest pulse of one workout is a lower bound on the true maximum, and
/// treating it as HRmax fabricates precision the data does not have.
///
/// Null when neither anchor exists — the caller must abstain, not default.
double? hrMaxForSession({double? observedCeilingBeforeSession, int? age}) {
  if (observedCeilingBeforeSession != null &&
      observedCeilingBeforeSession.isFinite &&
      observedCeilingBeforeSession > 0) {
    return observedCeilingBeforeSession;
  }
  if (age == null || age <= 0) return null;
  return 208.0 - 0.7 * age;
}

/// Result of the whole pass, for the derivation log line.
class Vo2maxHistoryResult {
  /// Sessions with at least one written row (estimate or abstention).
  final int sessions;
  /// Rows carrying an estimate.
  final int estimated;
  /// Rows carrying an abstention reason.
  final int abstained;
  const Vo2maxHistoryResult({
    required this.sessions,
    required this.estimated,
    required this.abstained,
  });
  bool get didWork => sessions > 0;
}

/// The stored RHR value as of [dayLabel] — the LAST MEASURED value on a
/// day strictly BEFORE the session's date, so a later-measured RHR is never
/// passed off as historically available. Falls back to the user's manual
/// resting HR when no series value predates the session; null when neither
/// exists — never a population default.
///
/// MEASURED ONLY: a vendor-imported day's `rhr` is another algorithm's
/// derived number, not this person's measurement, and this pass grades real
/// estimates against this anchor. `metricSeries`'s own doc requires
/// `measuredOnly` for anything that COMPUTES against the series — same rule
/// as every baseline read in this repo. [importedDates] is passed in by the
/// caller so a pass over many sessions resolves it ONCE, not per session.
double? restingHrAsOfRows(
  List<Map<String, dynamic>> rows,
  Set<String> imported,
  String dayLabel, {
  int? manual,
}) {
  double? best;
  String? bestDate;
  for (final r in rows) {
    final d = r['date'] as String?;
    final v = (r['value'] as num?)?.toDouble();
    if (d == null || v == null || !v.isFinite) continue;
    if (imported.contains(d)) continue;
    if (d.compareTo(dayLabel) >= 0) continue;
    if (bestDate == null || d.compareTo(bestDate) > 0) {
      best = v;
      bestDate = d;
    }
  }
  if (best != null) return best;
  if (manual != null && manual > 0) return manual.toDouble();
  return null;
}



/// Run the retrospective pass over the stored history. INCREMENTAL by
/// default: only sessions that have `workout_split` rows but no
/// `vo2max_history` rows yet are walked, so a session finalized after the
/// first pass is picked up by the next derive (the freshness payload's
/// [kVo2maxHistoryFormulaVersion] no longer ends the pass — it only marks
/// which chain the stored rows were produced by). A formula bump (or
/// [force]) re-runs the FULL pass once, replacing every session's rows in
/// place — repeated processing never duplicates.
Future<Vo2maxHistoryResult> backfillVo2maxHistory({
  required Map<String, dynamic> Function() getProfileMap,
  bool force = false,
}) async {
  const none = Vo2maxHistoryResult(sessions: 0, estimated: 0, abstained: 0);
  // Gate: a stored payload carrying the CURRENT formula version means the
  // full pass already ran — run incrementally. A missing or version-mismatched
  // payload (first run, or a bump) runs the FULL pass once. The old payload
  // shape `{'done': true}` carries no version and therefore re-runs full
  // exactly once, then upgrades itself to the versioned shape.
  var full = force;
  if (!force) {
    final gate = await LocalDb.computeFreshness(kVo2maxHistoryFreshnessKey);
    String? gateVersion;
    if (gate != null) {
      try {
        gateVersion =
            (jsonDecode(gate['payload_json'] as String? ?? '') as Map?)
                ?['formula_version'] as String?;
      } catch (_) {
        gateVersion = null;
      }
    }
    full = gateVersion != kVo2maxHistoryFormulaVersion;
  }
  final profile = Profile.fromMap(getProfileMap());
  final now = DateTime.now().millisecondsSinceEpoch;

  // One joined query: splits with their parent session's type/start_ts, so
  // the per-session anchors are resolved without a per-row round trip.
  // Incremental mode keeps only sessions with no history rows yet — the
  // (session_id, km) primary key makes the NOT EXISTS probe cheap.
  final db = await LocalDb.instance;
  final splitRows = await db.rawQuery(
    "SELECT ws.session_id, ws.km, ws.meters, ws.duration_sec, ws.avg_hr, "
    'ws.net_elev_m, s.type, s.start_ts '
    'FROM workout_split ws JOIN sessions s ON s.id = ws.session_id '
    '${full ? '' : 'WHERE NOT EXISTS (SELECT 1 FROM vo2max_history h '
        'WHERE h.session_id = ws.session_id) '}\n'
    'ORDER BY s.start_ts ASC, ws.km ASC',
  );
  if (splitRows.isEmpty) {
    if (full) {
      await LocalDb.putComputeFreshness(kVo2maxHistoryFreshnessKey,
          jsonEncode({'formula_version': kVo2maxHistoryFormulaVersion}));
    }
    return none;
  }
  // Anchor inputs, read ONCE for the whole pass (they were per-session
  // queries before: one full-series read + one ceiling read PER SESSION,
  // which is both an N+1 and a full scan of `metric_series` each time).
  final rhrRows = await LocalDb.metricSeries('rhr');
  final importedDates = await LocalDb.importedDates();
  final ceiling = await LocalDb.observedHrCeiling();
  final ceilingDay = ceiling?.date;
  final ceilingBpm = ceiling?.bpm;

  // Session-level anchors, resolved once per session id (splitRows are
  // ordered by session, so consecutive rows share one lookup).
  final hrMaxBy = <String, double?>{};
  final rhrBy = <String, double?>{};
  String? lastSessionId;
  for (final r in splitRows) {
    final id = r['session_id'] as String?;
    if (id == null || id == lastSessionId) continue;
    lastSessionId = id;
    final startTs = (r['start_ts'] as num?)?.toInt();
    if (startTs == null) {
      hrMaxBy[id] = null;
      rhrBy[id] = null;
      continue;
    }
    final day = dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch(startTs * 1000));
    hrMaxBy[id] = hrMaxForSession(
      observedCeilingBeforeSession:
          (ceilingDay == null || ceilingBpm == null)
              ? null
              : (ceilingDay.compareTo(day) < 0 ? ceilingBpm : null),
      age: profile.ageYears,
    );
    rhrBy[id] = restingHrAsOfRows(rhrRows, importedDates, day,
        manual: profile.restingHrManual);
  }

  var estimated = 0, abstained = 0;
  final perSession = <String, List<Map<String, Object?>>>{};
  // BOUTS, not isolated splits: rows arrive ordered (session, km), so
  // consecutive usable rows of one session form one contiguous bout and are
  // graded TOGETHER (see vo2maxFromHistoricalBout). A row that is unusable
  // ends the current bout; anchors-missing ends it too (the bout is only as
  // gradable as its session's anchors).
  Vo2maxHistorySplit? usableOf(Map<String, dynamic> r) {
    final meters = (r['meters'] as num?)?.toDouble();
    final dur = (r['duration_sec'] as num?)?.toInt();
    if (meters == null || dur == null) return null;
    return Vo2maxHistorySplit(
      sessionId: r['session_id'] as String,
      sessionType: r['type'] as String?,
      km: (r['km'] as num).toInt(),
      meters: meters,
      durationSec: dur,
      avgHrBpm: (r['avg_hr'] as num?)?.toDouble(),
      netElevM: (r['net_elev_m'] as num?)?.toDouble(),
    );
  }

  void bank(String id, int startTs, double? hrMax, double? rhr,
      Vo2maxHistorySplitResult res) {
    if (res.present) {
      estimated++;
    } else {
      abstained++;
    }
    perSession.putIfAbsent(id, () => []).add({
      'km': res.km,
      'activity_ts': startTs,
      'vo2max': res.vo2max,
      'absence_reason': res.absenceReason,
      'method': kVo2maxHistoryMethod,
      'formula_version': kVo2maxHistoryFormulaVersion,
      'hr_max_bpm': hrMax ?? 0,
      'resting_hr_bpm': rhr ?? 0,
      'computed_at': now,
    });
  }

  var bout = <Vo2maxHistorySplit>[];
  String? boutSession;
  int boutStartTs = 0;
  double? boutHrMax, boutRhr;

  void flushBout() {
    if (bout.isEmpty) return;
    final res = vo2maxFromHistoricalBout(bout,
        restingHrBpm: boutRhr!, hrMaxBpm: boutHrMax!);
    bank(boutSession!, boutStartTs, boutHrMax, boutRhr, res);
    bout = <Vo2maxHistorySplit>[];
  }

  for (final r in splitRows) {
    final id = r['session_id'] as String?;
    final km = (r['km'] as num?)?.toInt();
    if (id == null || km == null) continue;
    final startTs = (r['start_ts'] as num?)?.toInt() ?? 0;
    final hrMax = hrMaxBy[id];
    final rhr = rhrBy[id];
    final splitSessionChanged = id != boutSession;
    if (bout.isNotEmpty &&
        (splitSessionChanged || hrMax != boutHrMax || rhr != boutRhr)) {
      flushBout();
    }
    if (hrMax == null || rhr == null) {
      // Anchors missing: machine-readable why, never a default value. The
      // row is still banked (per-km visibility of the reason), but it can
      // never join a bout.
      bank(
          id,
          startTs,
          hrMax,
          rhr,
          Vo2maxHistorySplitResult(
            sessionId: id,
            km: km,
            vo2max: null,
            absenceReason: hrMax == null
                ? 'no_hr_max_available'
                : 'no_resting_hr_available',
          ));
      continue;
    }
    final usable = usableOf(r);
    if (usable == null) {
      // An unusable row ends the running bout and is banked with its own
      // reason (computeSplits guarantees meters/duration; null here is a
      // malformed row, and the honest answer is no estimate from it).
      flushBout();
      bank(
          id,
          startTs,
          hrMax,
          rhr,
          Vo2maxHistorySplitResult(
            sessionId: id,
            km: km,
            vo2max: null,
            absenceReason: 'no_completed_km_split',
          ));
      continue;
    }
    if (bout.isEmpty) {
      boutSession = id;
      boutStartTs = startTs;
      boutHrMax = hrMax;
      boutRhr = rhr;
    }
    bout.add(usable);
  }
  flushBout();
  for (final e in perSession.entries) {
    await LocalDb.putVo2maxHistory(e.key, e.value);
  }
  await LocalDb.putComputeFreshness(kVo2maxHistoryFreshnessKey, jsonEncode(
      {'formula_version': kVo2maxHistoryFormulaVersion, 'estimated': estimated}));
  return Vo2maxHistoryResult(
      sessions: perSession.length, estimated: estimated, abstained: abstained);
}
