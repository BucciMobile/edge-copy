// BP research capture — pair a cuff reading the user just took with the
// band's own decoded data from the minutes around that instant.
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


/// Window half-widths around the cuff instant (default ±2 min): the frozen
/// window covers [kBpResearchWindowPreMs] before the reference instant and
/// [kBpResearchWindowPostMs] after it. Lives here, next to the capture
/// logic, so the model file has no dependency direction to argue about.
const int kBpResearchWindowPreMs = 2 * 60 * 1000;
const int kBpResearchWindowPostMs = 2 * 60 * 1000;

/// The frozen band window around one reference instant. Every field is
/// nullable for the same reason the storage layer's columns are: a stat the
/// window could not honestly compute (no valid HR, no beats) is absent, not
/// zero.
class BpResearchWindow {
  const BpResearchWindow({
    required this.windowStartMs,
    required this.windowEndMs,
    this.onehzRows,
    this.rrBeats,
    this.hrMean,
    this.rrMsMean,
    this.rrMsMin,
    this.rrMsMax,
    this.rmssdMs,
    this.metaJson,
  });

  final int windowStartMs;
  final int windowEndMs;
  final int? onehzRows;
  final int? rrBeats;
  final double? hrMean;
  final double? rrMsMean;
  final double? rrMsMin;
  final double? rrMsMax;
  final double? rmssdMs;

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
    this.posture,
    this.conditions,
    this.window,
  });

  final int measuredAtMs;
  final double systolicMmHg;
  final double diastolicMmHg;
  final int capturedAtMs;

  /// The cuff's own name ('OMRON', 'Withings BPM', …). NULL when the user
  /// typed a bare pair of numbers with no device named.
  final String? device;
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

/// Compute the frozen band window around [measuredAtMs] from the decoded
/// store, pure and testable without a database (pass the rows in).
///
/// Window: measured instant minus/plus [preMs]/[postMs] (default ±2 min,
/// [kBpResearchWindowPreMs]/[kBpResearchWindowPostMs]). Reads ONLY already-decoded
/// tables — `decoded_onehz` (HR) and `decoded_rr` (beat intervals). No raw
/// archive, no re-decode, nothing derived: the point is to freeze exactly
/// what the app already holds at the moment of the cuff reading.
BpResearchWindow? researchWindowFrom({
  required int measuredAtMs,
  required List<Map<String, Object?>> onehzRows,
  required List<Map<String, Object?>> rrRows,
  int? preMs,
  int? postMs,
  String? deviceId,
  String? metaJson,
}) {
  final pre = preMs ?? kBpResearchWindowPreMs;
  final post = postMs ?? kBpResearchWindowPostMs;
  final start = measuredAtMs - pre;
  final end = measuredAtMs + post;

  // decoded_onehz.rec_ts is epoch SECONDS; rr is rr_ts_ms (epoch ms).
  final onehz = onehzRows
      .where((r) {
        final ts = r['rec_ts'];
        return ts is int && ts * 1000 >= start && ts * 1000 <= end;
      })
      .toList(growable: false);
  final rr = rrRows
      .where((r) {
        final ts = r['rr_ts_ms'];
        return ts is int && ts >= start && ts <= end;
      })
      .toList(growable: false);

  if (onehz.isEmpty && rr.isEmpty) return null;

  // HR mean over VALID HR rows only — a run of hr_valid = 0 rows must not
  // drag an average toward zero, and absent validity is absent, not false.
  final hrs = onehz
      .map((r) => r['hr'])
      .whereType<int>()
      .where((h) => h > 0)
      .toList(growable: false);
  final hrMean = hrs.isEmpty
      ? null
      : hrs.reduce((a, b) => a + b) / hrs.length;

  final rrs = rr
      .map((r) => r['rr_ms'])
      .whereType<num>()
      .map((v) => v.toDouble())
      .toList(growable: false);
  double? rrMean, rrMin, rrMax, rmssd;
  if (rrs.isNotEmpty) {
    rrMean = rrs.reduce((a, b) => a + b) / rrs.length;
    rrMin = rrs.reduce((a, b) => a < b ? a : b);
    rrMax = rrs.reduce((a, b) => a > b ? a : b);
    // RMSSD over successive differences in window order (rr_ts_ms ASC is
    // the caller's contract). Too few beats to form one difference: absent.
    if (rrs.length >= 2) {
      var sumSq = 0.0;
      for (var i = 1; i < rrs.length; i++) {
        final d = rrs[i] - rrs[i - 1];
        sumSq += d * d;
      }
      rmssd = _sqrt(sumSq / (rrs.length - 1));
    }
  }

  return BpResearchWindow(
    windowStartMs: start,
    windowEndMs: end,
    onehzRows: onehz.isEmpty ? null : onehz.length,
    rrBeats: rr.isEmpty ? null : rr.length,
    hrMean: hrMean?.toDouble(),
    rrMsMean: rrMean,
    rrMsMin: rrMin,
    rrMsMax: rrMax,
    rmssdMs: rmssd,
    metaJson: metaJson,
  );
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
