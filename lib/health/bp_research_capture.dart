// BP research capture — pair a cuff reading with the band's own decoded data
// from the minutes around the MEASUREMENT instant (not the entry instant).
//
// EXPERIMENTAL / DEVELOPER-ONLY. This exists to build a paired dataset a
// human can analyse OUTSIDE this app (CSV export); it is not a blood
// pressure feature and never becomes one. The same guard that fences
// `imported_measurement` applies twice over here: nothing in `compute/`,
// nothing that writes `day_result` / `metric_series`, and nothing that
// writes to HealthKit / Health Connect may read these tables — a wrist
// series regressed against cuff readings inside this app is a
// cuffless-blood-pressure claim from an uncleared device, which is exactly
// the category that earned WHOOP an FDA Warning Letter in Jul 2025.
//
// A capture with no band data at that instant is stored as a capture with a
// NULL window. Missing is missing — never 0, never a fabricated average.
//
// v2 (this file's current shape) separates three instants the v1 capture
// conflated: the MEASUREMENT instant (when the cuff actually squeezed), the
// ENTRY instant (when the user typed the pair in — a retro capture can be
// entered hours later), and the WINDOW instants. A retro capture is paired
// with the historical sensor data of its measurement instant, never with
// whatever the band happens to hold at entry time.

import 'dart:math' show sqrt;

//
// TIME SEMANTICS (honest by construction):
//   · The UI records only a MINUTE-precision instant — either the time the
//     reading was taken (back-dated) or the entry moment (field empty). The
//     entry moment is a usable pairing anchor ONLY when the user records
//     the reading right away; it is stored as the measured instant with
//     time_precision = 'minute' and is never claimed to be the exact
//     inflation start. No invented start/finish instants are fabricated.
//   · The window is the rest window BEFORE the measurement instant and the
//     product exposes no post-measurement window at all (Option 1 of the
//     pending-window review): a window that would reach into the future
//     cannot be produced by the UI, so 'pending' remains an internal,
//     data-level state only.

/// Feature-schema version of the window computation. Bumped whenever a
/// window field's MEANING changes (not its mere presence): exports carry it
/// so an analysis can tell which formula produced which column.
/// v3: coverage counts VALID HR seconds only (v2 counted raw deduplicated
/// rows); RR beats are keyed by their true beat identity (beat_ts_ms when
/// present, else (rr_ts_ms, beat_index)) instead of being deduplicated by
/// the whole-second rr_ts_ms; the window is half-open [start, end).
const int kResearchFeatureVersion = 3;

/// Rest window BEFORE the cuff measurement instant (engineering default,
/// 5 minutes): the feature window is
/// [measurement_instant − pre, measurement_instant). The cuff's own
/// inflation must not enter the feature window unchecked — ending the
/// window at the measurement instant keeps it out by construction.
/// A documented research parameter, not a validated physiological constant.
const int kResearchRestPreMs = 5 * 60 * 1000;

/// The product exposes ONLY the pre-measurement rest window; there is no
/// post-measurement window and no UI path that could produce one. Kept as a
/// named constant so the design decision stays visible at the call sites.
const int kResearchWindowPostMs = 0;

/// Maximum gap between two successive beat intervals for them to count as
/// a CONTIGUOUS pair (engineering default, 2.5 s). RMSSD is only ever
/// computed over pairs that are genuinely adjacent in time — a difference
/// across a sensor gap is a fabrication, not a heart-rate-variability
/// sample. A documented research parameter, not a validated artifact rule.
const int kResearchMaxBeatGapMs = 2500;

/// The frozen band window around one measurement instant. Every field is
/// nullable for the same reason the storage layer's columns are: a stat the
/// window could not honestly compute is absent, not zero.
class BpResearchWindow {
  const BpResearchWindow({
    required this.windowStartMs,
    required this.windowEndMs,
    this.observedStartMs,
    this.observedEndMs,
    this.onehzRows,
    this.rrBeats,
    this.hrMean,
    this.rrMsMean,
    this.rrMsMin,
    this.rrMsMax,
    this.rmssdMs,
    this.validHrSeconds,
    this.validIntervalCount,
    this.validIntervalPairCount,
    this.coverageFraction,
    this.rejectedIntervalFraction,
    this.qualityStatus,
    required this.featureVersion,
    this.snapshotRevision,
    this.metaJson,
  });

  /// The REQUESTED window bounds — half-open [start, end) around the
  /// measurement instant. Half-open so a 5-minute window at 1 Hz holds at
  /// most exactly 300 seconds and coverage can never exceed 1.0 by
  /// counting both endpoints of a closed interval.
  final int windowStartMs;
  final int windowEndMs;

  /// What the data actually OBSERVED inside the requested window — the
  /// first and last VALID row time (a row with no usable value does not
  /// extend the observed signal; raw coverage is reported separately via
  /// [onehzRows]/[rrBeats], which count all in-window rows). Distinct from
  /// the requested bounds so an analysis can tell "the band was worn for
  /// the last minute of a five-minute window" from "the band was worn all
  /// five minutes".
  final int? observedStartMs;
  final int? observedEndMs;

  /// All in-window 1 Hz rows (raw, deduplicated by rec_ts) — raw coverage.
  final int? onehzRows;

  /// All in-window beat rows (raw, deduplicated by beat identity) — raw
  /// beat coverage.
  final int? rrBeats;

  final double? hrMean;
  final double? rrMsMean;
  final double? rrMsMin;
  final double? rrMsMax;
  final double? rmssdMs;

  // ── quality (v2) ──────────────────────────────────────────────────────
  /// 1 Hz rows with a valid HR — at 1 Hz that is seconds of valid signal.
  final int? validHrSeconds;

  /// Beat intervals that survived validation (finite, positive, sorted,
  /// deduplicated by beat identity). Intervals the analysis may use.
  final int? validIntervalCount;

  /// SUCCESSIVE interval pairs that are also CONTIGUOUS in time. The only
  /// pairs RMSSD is computed over.
  final int? validIntervalPairCount;

  /// valid_hr_seconds ÷ requested window seconds (half-open window).
  /// NULL when the window has no duration or no valid HR row at all —
  /// coverage of nothing is not 0%.
  final double? coverageFraction;

  /// Share of successive VALID interval pairs REJECTED as non-contiguous
  /// (gap in the beat series). Named for what it measures: a PAIR-rejection
  /// rate, not an interval-exclusion rate (the latter is visible via
  /// [rrBeats] vs [validIntervalCount]). NULL when there are no successive
  /// pairs to reject.
  final double? rejectedIntervalFraction;

  /// 'pending' | 'ok' | 'gappy' | 'no_data' — see [researchWindowFrom].
  final String? qualityStatus;

  /// Which feature schema computed these stats (see [kResearchFeatureVersion]).
  final int featureVersion;

  /// Which immutable snapshot revision the raw rows are frozen in (1, 2, …).
  /// Re-processing a capture writes a NEW revision and keeps the old one.
  final int? snapshotRevision;

  /// Provenance the analysis needs and nothing else: device_id, firmware
  /// string if known, sample counts by table. JSON, written verbatim.
  final String? metaJson;
}

/// One cuff reference reading plus its window, ready to store.
class BpResearchCapture {
  const BpResearchCapture({
    required this.measuredAtMs,
    required this.systolicMmHg,
    required this.diastolicMmHg,
    required this.capturedAtMs,
    required this.device,
    this.measurementStartedAtMs,
    this.measurementFinishedAtMs,
    this.timePrecision,
    this.posture,
    this.conditions,
    this.bandDeviceId,
    this.measurementSessionId,
    this.window,
  });

  /// Nominal measurement instant — the v1 identity of the capture and still
  /// the idempotency key together with [device]. This is the instant the
  /// user supplied (minute precision) — the time the cuff reading was TAKEN
  /// for a back-dated capture, or the ENTRY moment when the field was left
  /// empty (the reading was taken "just now"; the pairing anchor is the
  /// entry moment, never claimed to be the exact inflation start).
  final int measuredAtMs;

  /// When the cuff actually STARTED squeezing. Kept for data that has a
  /// real start instant; the current UI records a single minute-precision
  /// instant and leaves this NULL — absent stays absent.
  final int? measurementStartedAtMs;

  /// When the cuff finished. Optional: many cuffs report one instant only.
  /// If only a single measurement instant is known, this stays NULL — no
  /// invented duration.
  final int? measurementFinishedAtMs;

  /// 'minute' — the precision of [measuredAtMs] as recorded by the current
  /// UI. Documented so an analysis knows the pairing instant is not
  /// second-accurate; a future finer-grained UI would record 'second'.
  final String? timePrecision;

  /// When the pair was TYPED IN. A retro capture entered hours later has
  /// this far after its measurement instant.
  final int capturedAtMs;

  final double systolicMmHg;
  final double diastolicMmHg;

  /// The cuff's own name ('OMRON', 'Withings BPM', …). NULL when the user
  /// typed a bare pair of numbers with no device named. The CUFF device —
  /// never conflated with [bandDeviceId].
  final String? device;

  /// The band whose decoded data the window froze (the app's primary device
  /// id at capture time). Kept beside the capture so a future second band
  /// or a device swap can never silently mix signal origins.
  final String? bandDeviceId;

  /// Free-form session label for grouping multiple cuff readings of one
  /// sitting — they are NOT independent physiological states, and an
  /// analysis must be able to tell them apart from readings hours apart.
  final String? measurementSessionId;

  final String? posture;
  final String? conditions;

  /// Null when the band had nothing decoded in the window.
  final BpResearchWindow? window;
}

/// Same plausibility bounds as `health_measurement_import.dart`, for the
/// same reason: 400 mmHg is a cuff error, and a clamped reading is a
/// fabricated one. Out-of-bounds input is rejected, never corrected.
const (double, double) kResearchSystolicBounds = (50, 300);
const (double, double) kResearchDiastolicBounds = (20, 200);

/// The row key that identifies ONE beat: the measured sub-second instant
/// when the decoder provides it (`beat_ts_ms`), otherwise the whole-second
/// record time plus the beat's index within that record. rr_ts_ms alone is
/// rec_ts*1000 for EVERY beat of a record, so keying by it would collapse
/// all beats of a second into one and corrupt every RMSSD.
int _beatKey(Map<String, Object?> r) {
  final beatTs = r['beat_ts_ms'];
  if (beatTs is num && beatTs > 0) return beatTs.toInt();
  final ts = r['rr_ts_ms'];
  final idx = r['beat_index'];
  return ((ts is num ? ts.toInt() : 0) << 8) | (idx is num ? idx.toInt() : 0);
}

/// The beat's position on the time axis for continuity checks: the measured
/// instant when the decoder provides it, otherwise the whole-second record
/// time (a documented heuristic — beats of one second then share a time,
/// and pairs of those are still treated as contiguous, which can only
/// under-reject, never fabricate differences).
int _beatTimeMs(Map<String, Object?> r) {
  final beatTs = r['beat_ts_ms'];
  if (beatTs is num && beatTs > 0) return beatTs.toInt();
  final ts = r['rr_ts_ms'];
  return ts is num ? ts.toInt() : 0;
}

/// Compute the frozen band window around the MEASUREMENT instant
/// ([measuredAtMs]) from already-decoded rows, pure and testable without a
/// database (pass the rows in).
///
/// Window: [measurement_instant − preMs, measurement_instant + postMs) —
/// half-open. The default design is the 5-minute rest window BEFORE the
/// measurement ([kResearchRestPreMs], [kResearchWindowPostMs] = 0), so the
/// cuff's own inflation stays out of the feature window by construction.
///
/// Reads ONLY what the caller passes — `decoded_onehz` (HR) and
/// `decoded_rr` (beat intervals) rows. No raw archive, no re-decode,
/// nothing derived: the point is to freeze exactly what the app already
/// holds for the measurement instant, whenever in the past that was.
///
/// Quality rules (all documented engineering parameters, none claimed as
/// validated artifact thresholds):
///   · onehz rows are filtered to the half-open window, sorted, and
///     deduplicated by `rec_ts`;
///   · an HR row is valid when its `hr` is a finite positive number —
///     absent validity is absent, not false, and an invalid row never
///     enters the mean NOR the coverage (a run of hr = 0 off-skin rows
///     must not read as a worn band);
///   · beat rows are keyed by beat identity ([_beatKey]: beat_ts_ms when
///     present, else (rr_ts_ms, beat_index)) — NEVER by rr_ts_ms alone,
///     which is identical for every beat of a record;
///   · non-finite, zero, or negative interval values are rejected;
///   · an interval PAIR is valid only when the two intervals are
///     successive valid beats whose beat times are contiguous
///     (gap ≤ [kResearchMaxBeatGapMs]) — RMSSD is computed over those
///     pairs and ONLY those pairs, never across a sensor gap;
///   · [nowMs] decides pending: a window whose end lies in the future is
///     'pending' and must be finalized once it has elapsed. The UI never
///     produces one (Option 1: pre-measurement window only, future
///     measurement instants are refused); the state exists so data-level
///     callers cannot silently mislabel such a window as final.
BpResearchWindow? researchWindowFrom({
  required int measuredAtMs,
  required List<Map<String, Object?>> onehzRows,
  required List<Map<String, Object?>> rrRows,
  int? preMs,
  int? postMs,
  int? maxGapMs,
  int? nowMs,
  String? deviceId,
  String? metaJson,
}) {
  final pre = preMs ?? kResearchRestPreMs;
  final post = postMs ?? kResearchWindowPostMs;
  final gap = maxGapMs ?? kResearchMaxBeatGapMs;
  final start = measuredAtMs - pre;
  final end = measuredAtMs + post;

  // decoded_onehz.rec_ts is epoch SECONDS; rr is rr_ts_ms (epoch ms).
  // Filter to the HALF-OPEN window [start, end), then SORT, then
  // DEDUPLICATE by rec_ts (first row wins — a re-decoded duplicate is the
  // same second, not a new one).
  final onehz =
      onehzRows.where((r) {
        final ts = r['rec_ts'];
        return ts is num && ts * 1000 >= start && ts * 1000 < end;
      }).toList()..sort(
        (a, b) => ((a['rec_ts'] as num).toDouble()).compareTo(
          (b['rec_ts'] as num).toDouble(),
        ),
      );
  final onehzDedup = <Map<String, Object?>>[];
  {
    int? lastTs;
    for (final r in onehz) {
      final ts = (r['rec_ts'] as num).toInt();
      if (lastTs == ts) continue;
      lastTs = ts;
      onehzDedup.add(r);
    }
  }

  final rrAll = rrRows.where((r) {
    final ts = r['rr_ts_ms'];
    return ts is num && ts >= start && ts < end;
  }).toList()..sort((a, b) => _beatTimeMs(a).compareTo(_beatTimeMs(b)));
  // Dedup by BEAT IDENTITY, not by rr_ts_ms — beats of one record differ
  // in beat_index and, when the decoder provides it, beat_ts_ms.
  final rrDedup = <Map<String, Object?>>[];
  {
    int? lastKey;
    for (final r in rrAll) {
      final key = _beatKey(r);
      if (lastKey == key) continue;
      lastKey = key;
      rrDedup.add(r);
    }
  }

  if (onehzDedup.isEmpty && rrDedup.isEmpty) return null;

  // Valid HR rows only — a run of hr = 0 rows must not drag the average
  // toward zero AND must not count as observed signal (coverage).
  final validHrRows = onehzDedup
      .where((r) {
        final h = r['hr'];
        return h is num && h.isFinite && h > 0;
      })
      .toList(growable: false);
  final hrMean = validHrRows.isEmpty
      ? null
      : validHrRows
                .map((r) => (r['hr'] as num).toDouble())
                .reduce((a, b) => a + b) /
            validHrRows.length;
  // 1 Hz: one valid row is one second of valid signal. This is the number
  // coverage is computed from — valid seconds, not raw rows.
  final validHrSeconds = validHrRows.isEmpty ? null : validHrRows.length;

  // Valid intervals: finite, positive, beat-keyed. Raw vs valid counts are
  // kept apart so an analysis can see how much of the beat series survived.
  final validIntervals = <(int, double)>[]; // (beat_time_ms, rr_ms)
  for (final r in rrDedup) {
    final v = r['rr_ms'];
    if (v is num && v.isFinite && v > 0) {
      validIntervals.add((_beatTimeMs(r), v.toDouble()));
    }
  }

  double? rrMean, rrMin, rrMax, rmssd;
  var validPairs = 0;
  if (validIntervals.isNotEmpty) {
    final values = validIntervals.map((p) => p.$2).toList(growable: false);
    rrMean = values.reduce((a, b) => a + b) / values.length;
    rrMin = values.reduce((a, b) => a < b ? a : b);
    rrMax = values.reduce((a, b) => a > b ? a : b);
    // RMSSD over CONTIGUOUS successive pairs only: the two beats must be
    // adjacent in time (gap ≤ [gap]). A difference across a sensor gap is a
    // fabrication, not an HRV sample.
    if (validIntervals.length >= 2) {
      var sumSq = 0.0;
      for (var i = 1; i < validIntervals.length; i++) {
        if (validIntervals[i].$1 - validIntervals[i - 1].$1 > gap) continue;
        final d = validIntervals[i].$2 - validIntervals[i - 1].$2;
        sumSq += d * d;
        validPairs++;
      }
      if (validPairs > 0) rmssd = sqrt(sumSq / validPairs);
    }
  }

  final pairTotal = validIntervals.length >= 2 ? validIntervals.length - 1 : 0;
  final rejectedPairFraction = pairTotal == 0
      ? null
      : 1.0 - (validPairs / pairTotal);

  final windowSeconds = (end - start) / 1000.0;
  final coverage = validHrSeconds == null || windowSeconds <= 0
      ? null
      : validHrSeconds / windowSeconds;

  // Quality status — an honest verdict, not a fabricated confidence number.
  //   pending  — the window extends into the future; finalize later. Not
  //              producible from the UI (future instants are refused); a
  //              data-level caller that still passes one gets an honest
  //              label instead of a silently "final" window.
  //   no_data  — nothing valid survived in either series.
  //   gappy    — over half the successive pairs were rejected across gaps,
  //              or under half the window has valid HR: usable, flag it.
  //   ok       — otherwise.
  String status;
  if (nowMs != null && end > nowMs) {
    status = 'pending';
  } else if (validHrRows.isEmpty && validIntervals.isEmpty) {
    status = 'no_data';
  } else if ((rejectedPairFraction != null && rejectedPairFraction > 0.5) ||
      (coverage != null && coverage < 0.5)) {
    status = 'gappy';
  } else {
    status = 'ok';
  }

  int? observedStart;
  int? observedEnd;
  final o1 = validHrRows.isNotEmpty
      ? (validHrRows.first['rec_ts'] as num).toInt() * 1000
      : null;
  final o2 = validIntervals.isNotEmpty ? validIntervals.first.$1 : null;
  final e1 = validHrRows.isNotEmpty
      ? (validHrRows.last['rec_ts'] as num).toInt() * 1000
      : null;
  final e2 = validIntervals.isNotEmpty ? validIntervals.last.$1 : null;
  if (o1 != null && o2 != null) {
    observedStart = o1 < o2 ? o1 : o2;
    observedEnd = (e1 ?? o1) > (e2 ?? o2) ? (e1 ?? o1) : (e2 ?? o2);
  } else {
    observedStart = o1 ?? o2;
    observedEnd = e1 ?? e2;
  }

  return BpResearchWindow(
    windowStartMs: start,
    windowEndMs: end,
    observedStartMs: observedStart,
    observedEndMs: observedEnd,
    onehzRows: onehzDedup.isEmpty ? null : onehzDedup.length,
    rrBeats: rrDedup.isEmpty ? null : rrDedup.length,
    hrMean: hrMean,
    rrMsMean: rrMean,
    rrMsMin: rrMin,
    rrMsMax: rrMax,
    rmssdMs: rmssd,
    validHrSeconds: validHrSeconds,
    validIntervalCount: validIntervals.isEmpty ? null : validIntervals.length,
    validIntervalPairCount: validPairs == 0 ? null : validPairs,
    coverageFraction: coverage,
    rejectedIntervalFraction: rejectedPairFraction,
    qualityStatus: status,
    featureVersion: kResearchFeatureVersion,
    metaJson: metaJson,
  );
}

/// The rows a snapshot freezes, so re-processing is reproducible: the exact
/// onehz and rr rows that produced a window revision, as plain JSON.
class BpResearchSnapshotRows {
  const BpResearchSnapshotRows({required this.onehzRows, required this.rrRows});

  /// The filtered, sorted, deduplicated rows the window computation saw.
  final List<Map<String, Object?>> onehzRows;
  final List<Map<String, Object?>> rrRows;
}
