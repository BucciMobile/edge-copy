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
// conflated: the MEASUREMENT instant (when the cuff actually squeezed),
// the ENTRY instant (when the user typed the pair in — a retro capture can
// be entered hours later), and the WINDOW instants. A retro capture is
// paired with the historical sensor data of its measurement instant, never
// with whatever the band happens to hold at entry time.

/// Feature-schema version of the window computation. Bumped whenever a
/// window field's MEANING changes (not its mere presence): exports carry it
/// so an analysis can tell which formula produced which column.
const int kResearchFeatureVersion = 2;

/// Rest window BEFORE the cuff measurement starts (engineering default,
/// 5 minutes): the feature window is [measurement_start − pre, measurement_start].
/// The cuff's own inflation must not enter the feature window unchecked —
/// ending the window at the measurement start keeps it out by construction.
/// A documented research parameter, not a validated physiological constant.
const int kResearchRestPreMs = 5 * 60 * 1000;

/// Optional window AFTER the measurement start. Default 0: the preferred
/// research design uses only the pre-measurement rest window. A non-zero
/// value may include the inflation itself, so a window whose end lies in
/// the future is stored as pending and finalized only after it has fully
/// elapsed and the band has had time to sync.
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

  /// The REQUESTED window bounds ([start, end] around the measurement).
  final int windowStartMs;
  final int windowEndMs;

  /// What the data actually OBSERVED inside the requested window — the
  /// first and last valid row time. Distinct from the requested bounds so
  /// an analysis can tell "the band was worn for the last minute of a
  /// five-minute window" from "the band was worn all five minutes".
  final int? observedStartMs;
  final int? observedEndMs;

  final int? onehzRows;
  final int? rrBeats;
  final double? hrMean;
  final double? rrMsMean;
  final double? rrMsMin;
  final double? rrMsMax;
  final double? rmssdMs;

  // ── quality (v2) ─────────────────────────────────────────────────────────
  /// 1 Hz rows with a valid HR — at 1 Hz that is seconds of valid signal.
  final int? validHrSeconds;

  /// Beat intervals that survived validation (sorted, deduplicated,
  /// finite, positive). Intervals the analysis may legitimately use.
  final int? validIntervalCount;

  /// SUCCESSIVE interval pairs that are also CONTIGUOUS in time (gap ≤
  /// [kResearchMaxBeatGapMs]). The only pairs RMSSD is computed over.
  final int? validIntervalPairCount;

  /// valid_hr_seconds ÷ requested window seconds. NULL when the window has
  /// no duration or no 1 Hz rows at all — coverage of nothing is not 0%.
  final double? coverageFraction;

  /// Share of successive interval pairs REJECTED as non-contiguous (gap in
  /// the beat series). NULL when there are no pairs to reject.
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
    this.posture,
    this.conditions,
    this.bandDeviceId,
    this.measurementSessionId,
    this.window,
  });

  /// Nominal measurement instant — the v1 identity of the capture and still
  /// the idempotency key together with [device]. For v2 captures this is
  /// the measurement START when the user supplied a real instant.
  final int measuredAtMs;

  /// When the cuff actually STARTED squeezing. NULL on v1 rows (their
  /// measuredAtMs doubles as both) — absent stays absent, it is not
  /// backfilled with measuredAtMs.
  final int? measurementStartedAtMs;

  /// When the cuff finished. Optional: many cuffs report one instant only.
  /// If only a single measurement instant is known, the pair fields above
  /// carry that instant and this stays NULL — no invented duration.
  final int? measurementFinishedAtMs;

  /// When the pair was TYPED IN. A retro capture entered hours later has
  /// this far after its measurement instants.
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

/// Compute the frozen band window around the MEASUREMENT instant
/// ([measuredAtMs]) from already-decoded rows, pure and testable without a
/// database (pass the rows in).
///
/// Window: [measurement_start − preMs, measurement_start + postMs] — the
/// default design is the 5-minute rest window BEFORE the measurement
/// ([kResearchRestPreMs], [kResearchWindowPostMs] = 0), so the cuff's own
/// inflation stays out of the feature window by construction.
///
/// Reads ONLY what the caller passes — `decoded_onehz` (HR) and
/// `decoded_rr` (beat intervals) rows. No raw archive, no re-decode,
/// nothing derived: the point is to freeze exactly what the app already
/// holds for the measurement instant, whenever in the past that was.
///
/// Quality rules (all documented engineering parameters, none claimed as
/// validated artifact thresholds):
///   · onehz rows are sorted and deduplicated by `rec_ts`;
///   · an HR row is valid when its `hr` is a finite positive integer —
///     absent validity is absent, not false, and an invalid row never
///     enters the mean (it must not drag an average toward zero);
///   · intervals are sorted and deduplicated by `rr_ts_ms`; non-finite,
///     zero, or negative values are rejected outright;
///   · an interval PAIR is valid only when the two intervals are
///     contiguous in time (gap ≤ [kResearchMaxBeatGapMs]) — RMSSD is
///     computed over those pairs and ONLY those pairs, never across a
///     sensor gap;
///   · [nowMs] decides pending: a window whose end lies in the future is
///     'pending' and must be finalized once it has elapsed.
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
  // Filter, then SORT (epoch bases differ; rows may arrive unsorted), then
  // DEDUPLICATE by timestamp (first row wins — a re-decoded duplicate is
  // the same second, not a new one).
  final onehz = onehzRows
      .where((r) {
        final ts = r['rec_ts'];
        return ts is num && ts * 1000 >= start && ts * 1000 <= end;
      })
      .toList()
    ..sort((a, b) =>
        ((a['rec_ts'] as num).toDouble()).compareTo((b['rec_ts'] as num).toDouble()));
  final dedupedOnehz = <Map<String, Object?>>[];
  {
    int? lastTs;
    for (final r in onehz) {
      final ts = (r['rec_ts'] as num).toInt();
      if (lastTs == ts) continue;
      lastTs = ts;
      dedupedOnehz.add(r);
    }
  }
  final onehzDedup = dedupedOnehz;

  final rrAll = rrRows
      .where((r) {
        final ts = r['rr_ts_ms'];
        return ts is num && ts >= start && ts <= end;
      })
      .toList()
    ..sort((a, b) =>
        ((a['rr_ts_ms'] as num).toDouble()).compareTo((b['rr_ts_ms'] as num).toDouble()));
  final dedupedRr = <Map<String, Object?>>[];
  {
    int? lastTs;
    for (final r in rrAll) {
      final ts = (r['rr_ts_ms'] as num).toInt();
      if (lastTs == ts) continue;
      lastTs = ts;
      dedupedRr.add(r);
    }
  }
  final rrDedup = dedupedRr;

  if (onehzDedup.isEmpty && rrDedup.isEmpty) return null;

  // Valid HR rows only — a run of hr = 0 rows must not drag the average
  // toward zero, and non-finite values are rejected outright.
  final validHr = onehzDedup
      .map((r) => r['hr'])
      .whereType<num>()
      .map((v) => v.toDouble())
      .where((h) => h.isFinite && h > 0)
      .toList(growable: false);
  final hrMean =
      validHr.isEmpty ? null : validHr.reduce((a, b) => a + b) / validHr.length;
  final validHrSeconds =
      validHr.isEmpty ? null : onehzDedup.length; // 1 Hz: one row is one second

  // Valid intervals: finite, positive, deduplicated. Rejected ones are
  // counted so an analysis can see HOW MUCH of the beat series survived.
  final validIntervals = <(int, double)>[]; // (rr_ts_ms, rr_ms)
  for (final r in rrDedup) {
    final v = r['rr_ms'];
    if (v is num && v.isFinite && v > 0) {
      validIntervals.add(((r['rr_ts_ms'] as num).toInt(), v.toDouble()));
    }
  }

  double? rrMean, rrMin, rrMax, rmssd;
  var validPairs = 0;
  if (validIntervals.isNotEmpty) {
    final values = validIntervals.map((p) => p.$2).toList(growable: false);
    rrMean = values.reduce((a, b) => a + b) / values.length;
    rrMin = values.reduce((a, b) => a < b ? a : b);
    rrMax = values.reduce((a, b) => a > b ? a : b);
    // RMSSD over CONTIGUOUS successive pairs only: the two intervals must
    // be adjacent in time (gap ≤ [gap]). A difference across a sensor gap
    // is a fabrication, not an HRV sample.
    if (validIntervals.length >= 2) {
      var sumSq = 0.0;
      for (var i = 1; i < validIntervals.length; i++) {
        if (validIntervals[i].$1 - validIntervals[i - 1].$1 > gap) continue;
        final d = validIntervals[i].$2 - validIntervals[i - 1].$2;
        sumSq += d * d;
        validPairs++;
      }
      if (validPairs > 0) rmssd = _sqrt(sumSq / validPairs);
    }
  }

  final pairTotal = validIntervals.length >= 2 ? validIntervals.length - 1 : 0;
  final rejectedPairFraction =
      pairTotal == 0 ? null : 1.0 - (validPairs / pairTotal);

  final windowSeconds = (end - start) / 1000.0;
  final coverage =
      validHrSeconds == null || windowSeconds <= 0 ? null : validHrSeconds / windowSeconds;

  // Quality status — an honest verdict, not a fabricated confidence number.
  //   pending  — the window extends into the future; finalize later.
  //   no_data  — nothing valid survived in either series.
  //   gappy    — over half the pairs were rejected across gaps, or under
  //              half the window has valid HR: usable, flag it.
  //   ok       — otherwise.
  String status;
  if (nowMs != null && end > nowMs) {
    status = 'pending';
  } else if (validHr.isEmpty && validIntervals.isEmpty) {
    status = 'no_data';
  } else if ((rejectedPairFraction != null && rejectedPairFraction > 0.5) ||
      (coverage != null && coverage < 0.5)) {
    status = 'gappy';
  } else {
    status = 'ok';
  }

  return BpResearchWindow(
    windowStartMs: start,
    windowEndMs: end,
    observedStartMs: onehzDedup.isNotEmpty
        ? (onehzDedup.first['rec_ts'] as num).toInt() * 1000
        : (rrDedup.isNotEmpty ? (rrDedup.first['rr_ts_ms'] as num).toInt() : null),
    observedEndMs: onehzDedup.isNotEmpty
        ? (onehzDedup.last['rec_ts'] as num).toInt() * 1000
        : (rrDedup.isNotEmpty ? (rrDedup.last['rr_ts_ms'] as num).toInt() : null),
    onehzRows: onehzDedup.isEmpty ? null : onehzDedup.length,
    rrBeats: rrDedup.isEmpty ? null : rrDedup.length,
    hrMean: hrMean,
    rrMsMean: rrMean,
    rrMsMin: rrMin,
    rrMsMax: rrMax,
    rmssdMs: rmssd,
    validHrSeconds: validHr.isEmpty ? null : validHr.length,
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

double _sqrt(double v) => v <= 0 ? 0.0 : _sqrtNewton(v);
double _sqrtNewton(double v) {
  var x = v;
  var y = (x + 1) / 2;
  while ((y - x).abs() > 1e-12) {
    x = y;
    y = (x + v / x) / 2;
  }
  return y;
}
