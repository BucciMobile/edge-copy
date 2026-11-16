//
// activity_watch.dart — PR 3 of the deviation pipeline: the INACTIVITY WATCH
// and the RECOVERY TREND. Both are informational cards only — neither ever
// pushes. Pure and isolate-safe; wired into buildCrossDayBundle, which feeds
// it the same residuals, strain series and journal tags as the tier engine.
//
// Inactivity watch: a 7-day rolling day-strain total against a configurable
// weekly goal (default expressed in the app's own strain-points, anchored to
// the WHO ~150 min moderate activity/week guideline), and "well below your
// usual" counted day by day against the user's own trailing baseline. It
// never fires while the user is in an explicit rest state (rest-day journal
// tags) and never fabricates a week that was not worn.
//
// Recovery trend: the honest replacement for "overtraining detection" — a
// 7-night rolling HRV suppression with a rising 7-night resting HR, judged
// against the prior 28 settled nights, ONLY when the training load over the
// same window was normal or reduced. Wording stays "below your usual …
// despite normal load", never a syndrome or a diagnosis.

import 'dart:math' as math;

import '../data/day_label.dart' show calendarDaysBetween;
import 'workout_signals.dart' show kEconomyDeclinePct, kTrendMinEconomyDays;

/// Days in the inactivity rolling window.
const int kInactivityWindowDays = 7;

/// Trailing window the "usual" daily strain is read from.
const int kInactivityBaselineDays = 28;

/// Minimum strain readings in the baseline window before "usual" means
/// anything; below this the watch is quiet (calibrating), never green.
const int kInactivityMinStrainDays = 14;

/// A day counts as "below usual" when its strain is under this fraction of
/// the usual daily strain.
const double kInactivityDayBelowRatio = 0.6;

/// Consecutive below-usual days required before the watch says anything.
const int kInactivityMinDaysBelow = 7;

/// Default weekly activity goal, in strain-points per week. The public-health
/// anchor is the WHO guideline of ~150 min of moderate activity per week; on
/// this app's 0–21 strain scale that is about 6.4 strain/day, i.e. ~45 points
/// per week for an ordinarily active user. Editable in the Day Strain screen.
const double kDefaultWeeklyActivityGoal = 45.0;

/// Editable range for the weekly goal (strain-points/week).
const double kWeeklyActivityGoalMin = 10.0;
const double kWeeklyActivityGoalMax = 147.0;

/// Journal tag that marks an explicit rest day.
const String kRestDayTag = 'rest day';

/// Rest-day tags inside the window at or above this count suppress the watch:
/// a planned rest block is not inactivity.
const int kInactivityMaxRestDays = 2;

/// Nights in the recovery-trend rolling window.
const int kTrendWindowNights = 7;

/// Settled nights the trend's baseline is read from (kept disjoint from the
/// window, like the overreaching conjunction's split).
const int kTrendBaselineNights = 28;

/// The trend needs the z-scores to mean something: calibration stage >= 2
/// (>= 14 valid nights) required.
const int kTrendMinStage = 2;

/// A night counts as HRV-suppressed at this residual robust-z or below.
const double kTrendHrvZ = -1.0;

/// Suppressed nights required inside the 7-night window (">5 days sustained").
const int kTrendMinSuppressedNights = 6;

/// The 7-night mean resting-HR residual must have risen at least this much
/// (bpm) over the baseline median.
const double kTrendRhrRiseBpm = 1.5;

/// Load gate: the window's mean daily strain may exceed the baseline window's
/// mean by at most this much — "normal or reduced load".
const double kTrendLoadTolerance = 1.0;

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2.0;
}

double? _robustScale(List<double> xs) {
  if (xs.isEmpty) return null;
  final m = _median(xs)!;
  final mad = _median([for (final x in xs) (x - m).abs()]) ?? 0;
  if (mad > 0) return 1.4826 * mad;
  if (xs.length < 2) return null;
  final mean = xs.reduce((a, b) => a + b) / xs.length;
  var acc = 0.0;
  for (final x in xs) {
    acc += (x - mean) * (x - mean);
  }
  final sd = math.sqrt(acc / (xs.length - 1));
  return sd > 0 ? sd : null;
}

DateTime? _day(String s) {
  if (s.isEmpty) return null;
  return DateTime.tryParse('${s}T00:00:00Z');
}

/// The inactivity watch. Returns a state map, or null when there honestly is
/// nothing to say (a wear gap inside the window, too little strain history).
///
///   state 'firing'      — the card shows: 7-day strain under the goal AND
///                         >= [kInactivityMinDaysBelow] consecutive days below
///                         60% of the user's usual daily strain.
///   state 'rest'        — suppressed: >= 3 rest-day journal tags in the
///                         window. A planned rest block is not inactivity.
///   state 'ok'          — computed, not firing.
///
/// [strain] is the per-day day-strain series (null = no reading that day),
/// [journalTagsByDate] the journal tags per calendar day, [weeklyGoal] the
/// configured weekly strain-point goal.
Map<String, dynamic>? computeInactivity({
  required List<String> dates,
  required List<double?> strain,
  required Map<String, List<String>> journalTagsByDate,
  double weeklyGoal = kDefaultWeeklyActivityGoal,
}) {
  final n = dates.length;
  if (n == 0) return null;
  // Reference day = newest day with a strain reading. A day with no reading
  // is a gap, not a zero-strain day.
  var ref = -1;
  for (var i = n - 1; i >= 0; i--) {
    if (strain[i] != null) {
      ref = i;
      break;
    }
  }
  if (ref < 0) return null;
  final refDay = _day(dates[ref]);
  if (refDay == null) return null;

  // The last [kInactivityWindowDays] calendar days must all carry a reading —
  // a week with a hole in it is not a measured week.
  var windowComplete = true;
  var strain7 = 0.0;
  var windowDays = 0;
  for (var i = 0; i < n; i++) {
    final d = _day(dates[i]);
    if (d == null) continue;
    if (calendarDaysBetween(d, refDay) >= kInactivityWindowDays) continue;
    windowDays++;
    final v = strain[i];
    if (v == null) {
      windowComplete = false;
      continue;
    }
    strain7 += v;
  }
  if (!windowComplete || windowDays < kInactivityWindowDays) return null;

  // Usual daily strain over the trailing baseline window.
  final baseline = <double>[
    for (var i = 0; i < n; i++)
      if (strain[i] != null &&
          i != ref &&
          (() {
            final d = _day(dates[i]);
            if (d == null) return false;
            final back = calendarDaysBetween(d, refDay);
            return back >= kInactivityWindowDays &&
                back < kInactivityWindowDays + kInactivityBaselineDays;
          })())
        strain[i]!,
  ];
  if (baseline.length < kInactivityMinStrainDays) {
    return {'state': 'calibrating', 'date': dates[ref]};
  }
  final usual = _median(baseline)!;
  if (usual <= 0) return null;
  final belowAt = usual * kInactivityDayBelowRatio;

  // Consecutive below-usual days ending at the reference day. A calendar gap
  // or a missing reading breaks the run — silence is not a quiet day.
  var daysBelow = 0;
  var prev = refDay;
  for (var i = ref; i >= 0; i--) {
    final d = _day(dates[i]);
    if (d == null) break;
    if (calendarDaysBetween(d, prev) > 1) break;
    final v = strain[i];
    if (v == null || v >= belowAt) break;
    daysBelow++;
    prev = d;
  }

  // Explicit rest state inside the window suppresses the watch.
  var restDays = 0;
  for (var i = 0; i < n; i++) {
    final d = _day(dates[i]);
    if (d == null) continue;
    if (calendarDaysBetween(d, refDay) >= kInactivityWindowDays) continue;
    final tags = journalTagsByDate[dates[i]] ?? const [];
    if (tags.contains(kRestDayTag)) restDays++;
  }
  if (restDays > kInactivityMaxRestDays) {
    return {'state': 'rest', 'date': dates[ref], 'rest_days': restDays};
  }

  final firing = daysBelow >= kInactivityMinDaysBelow && strain7 < weeklyGoal;
  return {
    'state': firing ? 'firing' : 'ok',
    'date': dates[ref],
    'days_below': daysBelow,
    'strain7': strain7,
    'goal': weeklyGoal,
    'usual_daily': usual,
  };
}

/// The recovery trend. Returns a state map, or null when there is not enough
/// settled history (stage gate / baseline size / wear gap across the split).
///
///   state 'firing' — >= 6 of the last 7 settled nights with HRV residual z
///                    <= -1.0 AND the 7-night mean RHR residual at least
///                    +1.5 bpm over the baseline median AND the same window's
///                    mean strain normal or reduced vs the baseline window.
///   state 'ok'     — computed, not firing.
Map<String, dynamic>? computeRecoveryTrend({
  required List<String> dates,
  required List<bool> unsettled,
  required List<double?> rhrResid,
  required List<double?> hrvResid,
  required List<double?> strain,
  required int stage,
  // PR 4: per-day pace-vs-HR economy (workout_signals.dart), null on days
  // without a steady session. An alternative trigger for the same card.
  List<double?>? economy,
}) {
  final n = dates.length;
  if (n == 0 || stage < kTrendMinStage) return null;

  bool usable(int i, List<double?> s) =>
      !unsettled[i] && s[i] != null && s[i]!.isFinite;

  // Settled indices, oldest first.
  final settledIdx = <int>[
    for (var i = 0; i < n; i++)
      if (usable(i, rhrResid) && usable(i, hrvResid)) i,
  ];
  if (settledIdx.length < kTrendWindowNights + 10) return null;

  final window = settledIdx.sublist(
      math.max(0, settledIdx.length - kTrendWindowNights));
  final baselineIdx = settledIdx
      .sublist(
          0, math.max(0, settledIdx.length - kTrendWindowNights))
      .reversed
      .take(kTrendBaselineNights)
      .toList()
      .reversed
      .toList();
  if (baselineIdx.length < 14) return null;

  // The baseline must sit close to the window — a wear gap between them makes
  // the comparison stale, so the trend goes quiet rather than guessing.
  final winStart = _day(dates[window.first]);
  final baseEnd = _day(dates[baselineIdx.last]);
  if (winStart == null || baseEnd == null) return null;
  if (calendarDaysBetween(baseEnd, winStart) > kTrendBaselineNights) {
    return null;
  }

  final baseHrv = [for (final i in baselineIdx) hrvResid[i]!];
  final baseRhr = [for (final i in baselineIdx) rhrResid[i]!];
  final hrvScale = _robustScale(baseHrv);
  final hrvMedian = _median(baseHrv)!;
  final rhrMedian = _median(baseRhr)!;

  // A degenerate HRV baseline (no dispersion) cannot produce z-scores, so the
  // HRV pattern simply does not fire — the performance path below may still.
  var suppressed = 0;
  var hrvZSum = 0.0;
  var rhrSum = 0.0;
  final hrvZOk = hrvScale != null && hrvScale > 0;
  for (final i in window) {
    if (hrvZOk) {
      final z = (hrvResid[i]! - hrvMedian) / hrvScale;
      hrvZSum += z;
      if (z <= kTrendHrvZ) suppressed++;
    }
    rhrSum += rhrResid[i]!;
  }
  final rhrDelta = rhrSum / window.length - rhrMedian;

  // Load gate over the same calendar days: window mean vs baseline mean.
  double? meanStrainOver(List<int> idx) {
    final vals = <double>[
      for (final i in idx)
        if (strain[i] != null && strain[i]!.isFinite) strain[i]!,
    ];
    if (vals.isEmpty) return null;
    return vals.reduce((a, b) => a + b) / vals.length;
  }

  final winLoad = meanStrainOver(window);
  final baseLoad = meanStrainOver(baselineIdx);
  if (winLoad == null || baseLoad == null) return null;
  final loadNormalOrReduced = winLoad <= baseLoad + kTrendLoadTolerance;

  // PR 4: performance decrement — pace-per-heartbeat economy over the window
  // vs the baseline median. Declining economy at normal load is the honest
  // performance-decrement pattern (never an overtraining claim).
  var perfDecline = false;
  double? ecoDeltaPct;
  var ecoDays = 0;
  if (economy != null && economy.length == n) {
    final ecoWin = <double>[
      for (final i in window)
        if (economy[i] != null && economy[i]!.isFinite && economy[i]! > 0)
          economy[i]!,
    ];
    ecoDays = ecoWin.length;
    final ecoBaseVals = <double>[
      for (final i in baselineIdx)
        if (economy[i] != null && economy[i]!.isFinite && economy[i]! > 0)
          economy[i]!,
    ];
    final ecoBase = ecoBaseVals.isEmpty ? null : _median(ecoBaseVals);
    if (ecoBase != null && ecoBase > 0 && ecoWin.length >= kTrendMinEconomyDays) {
      final ecoWinMean = ecoWin.reduce((a, b) => a + b) / ecoWin.length;
      ecoDeltaPct = (ecoBase - ecoWinMean) / ecoBase;
      perfDecline = ecoDeltaPct >= kEconomyDeclinePct;
    }
  }

  final hrvPattern = suppressed >= kTrendMinSuppressedNights &&
      rhrDelta >= kTrendRhrRiseBpm;
  final firing = loadNormalOrReduced && (hrvPattern || perfDecline);
  return {
    'state': firing ? 'firing' : 'ok',
    'date': dates[window.last],
    'days_suppressed': suppressed,
    'hrv_z': hrvZSum / window.length,
    'rhr_delta_bpm': rhrDelta,
    'load_ratio': baseLoad > 0 ? winLoad / baseLoad : null,
    'via': hrvPattern ? 'hrv' : (perfDecline ? 'performance' : null),
    'economy_delta_pct': ecoDeltaPct,
    'days_economy': ecoDays,
  };
}
