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
import 'vo2max_activity_gate.dart'
    show acsmSpeedDomainReason, vo2maxEligibleActivity;

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
/// v3: (a) as-of ceiling resolution (the latest ceiling recorded BEFORE
/// the session, not the global max which may postdate it), (b) the
/// equation-domain grey-zone gate, (c) the fingerprint now covers anchors
/// and profile assumptions too — stored v2 rows are re-graded once on
/// the next derive because the freshness payload's version no longer
/// matches.
const String kVo2maxHistoryFormulaVersion = '3';

/// Anchor policy version — which anchors the history pass will grade
/// against and how they are resolved. v2: HRmax from the latest ceiling
/// OBSERVED STRICTLY BEFORE the session (as-of, not the global max) or
/// Tanaka with the CURRENT profile age (an explicitly documented
/// substitute assumption, see docs/VO2MAX.md); RHR from the last measured
/// metric_series value on a day strictly before the session (imported
/// days excluded), or the user's manual value (undated, a documented
/// substitute). Stored per row via the fingerprint, so an anchor policy
/// change re-walks every session.
const String kVo2maxAnchorPolicyVersion = '2';

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
  Vo2maxHistorySplitResult absent(String reason) => Vo2maxHistorySplitResult(
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
  // Release-safe: an empty list has no first km to bank a row under. The
  // pass never calls it empty (an unusable row is banked on its own), but
  // this is a public function and an assert is not an empty-input policy.
  if (splits.isEmpty) {
    throw ArgumentError.value(
      splits,
      'splits',
      'a bout needs at least one split',
    );
  }
  final first = splits.first;
  Vo2maxHistorySplitResult absent(String reason) => Vo2maxHistorySplitResult(
    sessionId: first.sessionId,
    km: first.km,
    vo2max: null,
    absenceReason: reason,
  );
  if (!vo2maxEligibleActivity(first.sessionType)) {
    return absent('unsupported_activity');
  }
  // Per-row eligibility, same rules the pass applies before a row may
  // join a bout (see _splitEligibilityReason). Kept here as a defensive
  // re-check: this function is public and a caller can hand it any list.
  for (final s in splits) {
    final reason = _splitEligibilityReason(s);
    if (reason != null) return absent(reason);
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
  final boutSpeed = meters / dur;
  final domainReason = acsmSpeedDomainReason(boutSpeed);
  if (domainReason != null) return absent(domainReason);
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

/// Machine-readable reason a split may NOT join a bout, or null when it
/// may. PURE and public so the eligibility rules are testable without a
/// database: everything the bout maths needs is checked HERE, before the
/// row can poison or end a bout. The rules, in order:
///   * activity type — the ACSM equations are foot-locomotion only.
///   * full km — the >=999 m rule of the live pass (a trailing partial
///     km has no fixed distance; its "speed" is not a pace anything
///     claimed, and the >=999 tolerance exists because km binning can
///     land slightly under 1000 m — a technical heuristic, not a
///     physiological threshold).
///   * finite positive distance and duration — NaN/Infinity/negative
///     numbers are malformed rows, not physiologically unqualifying ones.
///   * the split's OWN finite HR — the bout's duration-weighted HR mean
///     is only as good as every member's own average.
String? _splitEligibilityReason(Vo2maxHistorySplit s) {
  if (!vo2maxEligibleActivity(s.sessionType)) return 'unsupported_activity';
  if (!s.meters.isFinite || s.meters < kVo2maxFullSplitMinMeters) {
    return 'no_completed_km_split';
  }
  if (s.durationSec <= 0) return 'no_completed_km_split';
  if (s.avgHrBpm == null || !s.avgHrBpm!.isFinite || s.avgHrBpm! <= 0) {
    return 'no_steady_hr_for_split';
  }
  return null;
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

/// A STABLE fingerprint of one session's compute-relevant inputs — ALL of
/// them, not just the splits: session start and type, the split rows
/// (km, metres, duration, avg HR, net elevation), the RESOLVED anchors
/// (RHR and HRmax the session would be graded against) and the profile
/// assumptions that feed them, plus the anchor-policy and formula
/// versions. A later-arriving RHR measurement, a changed manual RHR, an
/// added profile age, a corrected session timestamp or a changed anchor
/// policy therefore all re-walk the session; unchanged inputs keep their
/// fingerprint.
///
/// STABILITY CONTRACT: NOT a Dart hashCode (not stable across isolates or
/// runs) and NOT wall-clock dependent (computed_at never enters). Built
/// as a canonical '|'/';'-delimited string over UTF-16 code units — the
/// inputs are ASCII/numeric session data, so code units == code points
/// here — hashed with a 64-bit FNV-1a masked to 64 bits on every step, so
/// the result is identical on web (where Dart ints are doubles) and VM
/// targets alike. Collision risk at 64 bits is negligible for a
/// per-session map of human-history size.
String vo2maxInputFingerprint(
  List<Map<String, dynamic>> splitRows, {
  required int sessionStartTs,
  required double? restingHrBpm,
  required double? hrMaxBpm,
  required int? profileAgeYears,
  required int? profileRestingHrManual,
}) {
  final buf = StringBuffer();
  buf.write(
    'v|$kVo2maxHistoryFormulaVersion|'
    '$kVo2maxAnchorPolicyVersion|$sessionStartTs|'
    '$profileAgeYears|$profileRestingHrManual|'
    '$restingHrBpm|$hrMaxBpm;',
  );
  for (final r in splitRows) {
    buf.write(r['km']);
    buf.write('|');
    buf.write(r['meters']);
    buf.write('|');
    buf.write(r['duration_sec']);
    buf.write('|');
    buf.write(r['avg_hr']);
    buf.write('|');
    buf.write(r['net_elev_m']);
    buf.write(';');
  }
  var h = 0xcbf29ce484222325;
  for (final c in buf.toString().codeUnits) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toRadixString(16);
}

/// Run the retrospective pass over the stored history. INCREMENTAL by
/// default: a session is walked when it has no `vo2max_history` rows yet
/// OR when its input FINGERPRINT (splits + type, see
/// [vo2maxInputFingerprint]) changed since the last pass — so
/// later-arriving HR joins, corrected splits and retyped sessions are
/// picked up by the next derive, while unchanged sessions cost one map
/// lookup each. A formula bump (or [force]) re-runs the FULL pass once,
/// replacing every session's rows in place — repeated processing never
/// duplicates. The per-session fingerprints live in the freshness payload
/// (one JSON map, bounded by the session count), not in a new column —
/// no schema change.
Future<Vo2maxHistoryResult> backfillVo2maxHistory({
  required Map<String, dynamic> Function() getProfileMap,
  bool force = false,
}) async {
  const none = Vo2maxHistoryResult(sessions: 0, estimated: 0, abstained: 0);
  // Gate: a stored payload carrying the CURRENT formula version means the
  // full pass already ran — run incrementally. A missing or
  // version-mismatched payload (first run, or a bump) runs the FULL pass
  // once, then upgrades itself to the versioned shape.
  var full = force;
  Map<String, String> knownFingerprints = {};
  if (!force) {
    final gate = await LocalDb.computeFreshness(kVo2maxHistoryFreshnessKey);
    String? gateVersion;
    if (gate != null) {
      try {
        final payload =
            jsonDecode(gate['payload_json'] as String? ?? '') as Map?;
        gateVersion = payload?['formula_version'] as String?;
        final fps = payload?['input_fingerprints'];
        if (fps is Map) {
          knownFingerprints = {
            for (final e in fps.entries)
              if (e.key is String && e.value is String)
                e.key as String: e.value as String,
          };
        }
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
  // ALWAYS all sessions — the incremental decision is per-session on the
  // input FINGERPRINT (a session with rows on disk but CHANGED inputs must
  // be re-walked too, which NOT EXISTS cannot see), and the full/incremental
  // distinction is only whether stored rows are overwritten in place.
  final db = await LocalDb.instance;
  final splitRows = await db.rawQuery(
    "SELECT ws.session_id, ws.km, ws.meters, ws.duration_sec, ws.avg_hr, "
    'ws.net_elev_m, s.type, s.start_ts '
    'FROM workout_split ws JOIN sessions s ON s.id = ws.session_id '
    'ORDER BY s.start_ts ASC, ws.km ASC',
  );
  if (splitRows.isEmpty) {
    if (full) {
      await LocalDb.putComputeFreshness(
        kVo2maxHistoryFreshnessKey,
        jsonEncode({'formula_version': kVo2maxHistoryFormulaVersion}),
      );
    }
    return none;
  }
  // Anchor inputs, read ONCE for the whole pass (they were per-session
  // queries before: one full-series read + one ceiling read PER SESSION,
  // which is both an N+1 and a full scan of `metric_series` each time).
  final rhrRows = await LocalDb.metricSeries('rhr');
  final importedDates = await LocalDb.importedDates();
  // The WHOLE ceiling series, ASC — the as-of anchor per session is the
  // latest value with date < session day, resolved in Dart from one read.
  // The global max ([LocalDb.observedHrCeiling]) is TODAY's view and may
  // postdate any given session; grading a historical session against it
  // would smuggle a later measurement in as a historical anchor.
  final ceilingRows = await LocalDb.metricSeries('hr_ceiling_bpm');

  // Session-level anchors, resolved once per session id (splitRows are
  // ordered by session, so consecutive rows share one lookup). Resolved for
  // ALL sessions, not only walked ones: the per-session input fingerprint
  // covers the resolved anchors, so the anchor maps must exist before the
  // fingerprint pass below can seal them.
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
    final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(startTs * 1000));
    // AS-OF ceiling: the LATEST ceiling recorded strictly BEFORE the
    // session's day (ceilingRows are date-ASC). Sessions after the last
    // ceiling see the global max; sessions BEFORE a later, harder workout
    // never see that later evidence.
    double? asOfCeilingBpm;
    for (final cr in ceilingRows) {
      final cd = cr['date'] as String?;
      final cv = (cr['value'] as num?)?.toDouble();
      if (cd == null || cv == null || !cv.isFinite) continue;
      if (cd.compareTo(day) >= 0) break;
      asOfCeilingBpm = cv;
    }
    hrMaxBy[id] = hrMaxForSession(
      observedCeilingBeforeSession: asOfCeilingBpm,
      age: profile.ageYears,
    );
    rhrBy[id] = restingHrAsOfRows(
      rhrRows,
      importedDates,
      day,
      manual: profile.restingHrManual,
    );
  }

  // Per-session input fingerprints (rows are ordered by session), used to
  // decide which sessions the incremental pass must (re-)walk. The
  // fingerprint covers the RESOLVED ANCHORS and profile assumptions too,
  // so an anchor/policy change re-walks without any split changing.
  final fingerprintOf = <String, String>{};
  {
    final rowsOfSession = <Map<String, dynamic>>[];
    String? cur;
    var curStartTs = 0;
    void seal() {
      if (cur == null) return;
      fingerprintOf[cur] = vo2maxInputFingerprint(
        rowsOfSession,
        sessionStartTs: curStartTs,
        restingHrBpm: rhrBy[cur],
        hrMaxBpm: hrMaxBy[cur],
        profileAgeYears: profile.ageYears,
        profileRestingHrManual: profile.restingHrManual,
      );
    }

    for (final r in splitRows) {
      final id = r['session_id'] as String?;
      if (id == null) continue;
      if (id != cur) {
        seal();
        cur = id;
        curStartTs = (r['start_ts'] as num?)?.toInt() ?? 0;
        rowsOfSession.clear();
      }
      rowsOfSession.add(r);
    }
    seal();
  }
  // The sessions the pass will actually (re-)walk. Full mode: everything.
  // Incremental: sessions whose fingerprint is new or changed.
  final walkSessions = full
      ? null // everything
      : <String>{
          for (final e in fingerprintOf.entries)
            if (knownFingerprints[e.key] != e.value) e.key,
        };
  if (walkSessions != null && walkSessions.isEmpty) {
    // Nothing changed: refresh only the stored fingerprint map so it stays
    // in sync with what is on disk (sessions may have been deleted).
    await LocalDb.putComputeFreshness(
      kVo2maxHistoryFreshnessKey,
      jsonEncode({
        'formula_version': kVo2maxHistoryFormulaVersion,
        'input_fingerprints': fingerprintOf,
      }),
    );
    return none;
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

  void bank(
    String id,
    int startTs,
    double? hrMax,
    double? rhr,
    Vo2maxHistorySplitResult res,
  ) {
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
    final res = vo2maxFromHistoricalBout(
      bout,
      restingHrBpm: boutRhr!,
      hrMaxBpm: boutHrMax!,
    );
    bank(boutSession!, boutStartTs, boutHrMax, boutRhr, res);
    bout = <Vo2maxHistorySplit>[];
  }

  for (final r in splitRows) {
    final id = r['session_id'] as String?;
    final km = (r['km'] as num?)?.toInt();
    if (id == null || km == null) continue;
    if (walkSessions != null && !walkSessions.contains(id)) continue;
    final startTs = (r['start_ts'] as num?)?.toInt() ?? 0;
    final hrMax = hrMaxBy[id];
    final rhr = rhrBy[id];
    // Anchors missing: machine-readable why, never a default value. The
    // row is banked (per-km visibility of the reason), it ends any running
    // bout, and it can never join one.
    if (hrMax == null || rhr == null) {
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
          absenceReason: hrMax == null
              ? 'no_hr_max_available'
              : 'no_resting_hr_available',
        ),
      );
      continue;
    }
    // ELIGIBILITY PER ROW, before the row can touch a bout: an invalid
    // row (no HR of its own, partial km, non-finite numbers, unsupported
    // activity) must END the running bout and be banked with its OWN
    // reason — the valid predecessors keep their estimate. The previous
    // shape added every well-formed row to the bout and graded the whole
    // list in vo2maxFromHistoricalBout, so ONE invalid trailing row
    // (a partial last km — the common case) abstained the entire bout
    // and threw away every valid km before it.
    final split = usableOf(r);
    final reason = split == null
        ? 'no_completed_km_split'
        : _splitEligibilityReason(split);
    if (reason != null) {
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
          absenceReason: reason,
        ),
      );
      continue;
    }
    // split is non-null here (a null usableOf row took the reason path
    // above), but Dart's flow analysis needs the demotion spelled out.
    final usableSplit = split;
    if (usableSplit == null) continue;
    // A bout is CONTIGUOUS: same session AND strictly consecutive km. A
    // gap (km 1 -> km 3) ends the running bout and starts a new one
    // instead of discarding the whole session — km 3's estimate is not
    // poisoned by km 2's absence.
    if (bout.isNotEmpty && (id != boutSession || km != bout.last.km + 1)) {
      flushBout();
    }
    if (bout.isEmpty) {
      boutSession = id;
      boutStartTs = startTs;
      boutHrMax = hrMax;
      boutRhr = rhr;
    }
    bout.add(usableSplit);
  }
  flushBout();
  for (final e in perSession.entries) {
    await LocalDb.putVo2maxHistory(e.key, e.value);
  }
  await LocalDb.putComputeFreshness(
    kVo2maxHistoryFreshnessKey,
    jsonEncode({
      'formula_version': kVo2maxHistoryFormulaVersion,
      'input_fingerprints': fingerprintOf,
    }),
  );
  return Vo2maxHistoryResult(
    sessions: perSession.length,
    estimated: estimated,
    abstained: abstained,
  );
}
