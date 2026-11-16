// CONTEXT MODEL — Layer 1 (baselines/calibration) + Layer 2 (expected
// deviation from context) of the deviation pipeline, PURE and ISOLATE-SAFE.
//
// The overnight detectors in `analytics` (illness CUSUM, multivariate anomaly,
// skin-temp flag) already standardise each signal against its own trailing
// robust baseline. What they cannot see is WHY a night moved: a hard training
// day, a short-sleep run, alcohol, a vaccination, travel or the luteal phase
// all push nightly RHR up and HRV down by the same order of magnitude as an
// emerging illness (Mishra et al., Nat Biotechnol Eng 2020;
// Natarajan et al., npj Digit Med 2020; cycle-phase shifts, PMC9005074;
// alcohol even at low doses, PLOS Digital Health ~21k adults). This module
// computes, per night, the EXPECTED deviation from that context, so the
// detectors can be fed the RESIDUAL (actual − expected) and only a deviation
// nothing explains counts.
//
// SHAPE: transparent, hand-tunable rules with every weight a named constant
// below — no ML model, so a reviewer can check the math in a diff. Every weight
// is an ESTIMATE-tier engineering bound, not a published constant; the
// published part is the direction and rough magnitude, cited per block.
//
// COMPATIBILITY: with no context present the expected offset is EXACTLY 0, so
// the residual equals the raw value and the detectors see byte-for-byte what
// they saw before this module existed. The personal baseline itself stays
// inside the detectors (they re-standardise whatever series they are handed),
// so this module subtracts ONLY the context term — never a baseline — and a
// no-context night is untouched.
//
// PURITY: no DB, no I/O, no Flutter, no DateTime.now(). Journal and cycle data
// arrive as plain maps/lists supplied by the caller (read on the DB isolate in
// derivation_engine.dart). DateTime use is `DateTime.tryParse(label)` on input
// strings only — deterministic, and UTC-anchored so DST cannot shift a
// calendar-day count.

import 'dart:math' as math;

import '../data/day_label.dart' show calendarDaysBetween, dayLabelBefore;
import 'workout_signals.dart'
    show
        kHrrLnCap,
        kHrrPoorDeltaBpm,
        kHrrRhrCapBpm,
        kLnHrvPerHrrPoorBpm,
        kLnHrvPerVolumeKg,
        kRhrBpmPerHrrPoorBpm,
        kRhrBpmPerVolumeKg,
        kVolumeLnCap,
        kVolumeRhrCapBpm;

// ── tunable weights (ESTIMATE-tier; direction/magnitude from the literature) ──

/// Expected next-night resting-HR rise per point of YESTERDAY's 0–21 strain.
/// A very hard day (strain ~18) raising nocturnal RHR by ~2–3 bpm is the
/// well-documented training-load effect.
const double kRhrBpmPerStrainYesterday = 0.15;

/// Same effect spread over the trailing 3 days of load.
const double kRhrBpmPerStrain3 = 0.08;

/// Same effect spread over the trailing 7 days of load (cumulative fatigue).
const double kRhrBpmPerStrain7 = 0.05;

/// Expected lnRMSSD suppression per point of yesterday's strain (a hard day
/// suppresses next-night HRV on the order of 10–20 %).
const double kLnHrvPerStrainYesterday = 0.008;

/// Same, averaged over the trailing 3 days.
const double kLnHrvPerStrain3 = 0.006;

/// Same, averaged over the trailing 7 days.
const double kLnHrvPerStrain7 = 0.010;

/// Expected RHR rise per minute of sleep debt (personal need − actual, summed
/// over the night itself and the two before it).
const double kRhrBpmPerSleepDebtMin = 0.02;

/// Expected lnRMSSD suppression per minute of sleep debt.
const double kLnHrvPerSleepDebtMin = 0.002;

/// Alcohol: nocturnal HR rebound, roughly dose-dependent (PLOS Digital Health,
/// ~21,000 adults: even low doses raise nocturnal HR and suppress recovery).
const double kAlcoholRhrBpmPerUnit = 1.5;
const double kAlcoholRhrBpmCap = 8.0;

/// Alcohol: HRV suppression in ln units per unit, capped.
const double kAlcoholLnHrvPerUnit = 0.15;
const double kAlcoholLnHrvCap = 0.60;

/// Late caffeine (≥200 mg after 16:00, the smart-wake confounder definition):
/// small RHR/HRV effect on the following night.
const double kLateCaffeineRhrBpm = 1.0;
const double kLateCaffeineLnHrv = 0.08;

/// A large late meal, journaled: same order as late caffeine.
const double kLateMealRhrBpm = 1.0;
const double kLateMealLnHrv = 0.08;

// Journal masks expressed in ROBUST-Z units (device-independent), converted to
// native units per night via that signal's own trailing robust scale. A
// vaccination raises skin temp and RHR and lowers HRV for 48–72 h; travel
// reduces sensitivity for 1–2 nights; a self-reported 'sick' day is treated as
// an expected deviation (near-full mask) — the user told us why the night
// moved, and the mask is recorded, never silent.
const double kVaccinationTempZ = 3.0;
const double kVaccinationRhrZ = 2.0;
const double kVaccinationRespZ = 1.0;
const double kVaccinationLnHrvZ = 2.0;

/// Nights after a 'vaccinated' entry that the mask covers (48–72 h).
const int kVaccinationMaskNights = 3;

const double kTravelRhrZ = 1.5;
const double kTravelLnHrvZ = 1.5;

/// Nights after a 'travel' entry that get reduced sensitivity.
const int kTravelMaskNights = 2;

const double kSickRhrZ = 3.0;
const double kSickLnHrvZ = 3.0;
const double kSickTempZ = 3.0;

/// A self-reported 'sick' tag masks the night it describes (same-day,
/// retrospective) and the night after (the +1 lag) — both arrive through
/// [_tagsForNight], which merges the previous and the current journal day.

/// Cycle stratification: the luteal-vs-follicular offset is EMPIRICAL (median
/// difference between the user's own luteal and non-luteal nights in the
/// window), used only when at least this many luteal nights exist — otherwise
/// the offset is 0 and the temp flag's own luteal annotation carries it.
const int kMinLutealNightsForOffset = 5;

/// Cap on the empirical luteal offset, in robust-z units, so one weird window
/// cannot manufacture a large mask.
const double kLutealOffsetZCap = 2.5;

// ── calibration stages (Layer 1 unlock) ──

/// Trailing window, in CALENDAR days, over which valid nights are counted.
const int kCalibrationWindowDays = 60;

/// Valid nights (settled, with a nightly RHR) needed per stage.
const int kStageCoarseFrom = 7; // 7–13: coarse deviation hints only
const int kStageStandardFrom = 14; // 14–29: z-scores active
const int kStageFullFrom = 30; // ≥30: full multi-signal sensitivity

/// A wear gap longer than this many calendar days drops the stage by one
/// (partial recalibration; the stale baseline is kept as a prior and
/// revalidated against new nights — never hard-reset).
const int kWearGapDays = 14;

/// Calibration stage labels, machine-readable, surfaced to the UI.
const List<String> kCalibrationStageLabels = [
  'calibrating',
  'coarse',
  'standardized',
  'full',
];

/// One signal's per-night residual + the masks that produced it.
class ContextResiduals {
  const ContextResiduals({
    required this.rhrResidual,
    required this.hrvResidual,
    required this.respResidual,
    required this.tempResidual,
    required this.masks,
    required this.calibration,
  });

  /// Nightly RHR minus the expected context offset (bpm). Null where the
  /// night has no RHR or is unsettled — never fabricated.
  final List<double?> rhrResidual;

  /// Nightly RMSSD minus the expected suppression (ms, raw domain — the
  /// detector standardises whatever it is handed).
  final List<double?> hrvResidual;

  /// Respiratory rate minus the expected context offset (breaths/min).
  final List<double?> respResidual;

  /// Raw nightly skin-temp mean minus the expected offset (device units —
  /// the temp flag standardises internally and must not be handed a z).
  final List<double?> tempResidual;

  /// Per night, the names of the context terms that were subtracted.
  final List<List<String>> masks;

  /// The Layer-1 calibration block (valid-night count, stage, gap rule,
  /// per-signal availability).
  final Map<String, dynamic> calibration;
}

/// Parse a 'YYYY-MM-DD' label to a UTC-anchored DateTime, or null.
DateTime? _day(String s) {
  if (s.isEmpty) return null;
  final d = DateTime.tryParse('${s}T00:00:00Z');
  return d;
}

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2.0;
}

double _mad(List<double> xs, double median) {
  if (xs.isEmpty) return 0;
  return _median([for (final x in xs) (x - median).abs()]) ?? 0;
}

double _sd(List<double> xs, double mean) {
  if (xs.length < 2) return 0;
  var acc = 0.0;
  for (final x in xs) {
    acc += (x - mean) * (x - mean);
  }
  return math.sqrt(acc / (xs.length - 1));
}

/// Robust scale (1.4826·MAD, SD fallback) of [xs], or null when the window
/// has no dispersion at all — then there is no scale to convert a z-mask
/// with, so the caller applies no z-term rather than inventing one.
double? _robustScale(List<double> xs) {
  if (xs.isEmpty) return null;
  final m = _median(xs)!;
  final mad = _mad(xs, m);
  if (mad > 0) return 1.4826 * mad;
  final sd = _sd(xs, xs.reduce((a, b) => a + b) / xs.length);
  return sd > 0 ? sd : null;
}

/// Per-night "is this date in the SECOND HALF of the cycle it belongs to",
/// parallel to [dates]. All-false when there is nothing to count from.
///
/// Each date walks back to its NEAREST PRECEDING logged start. The cycle's
/// length is the gap to the NEXT logged start; the still-open cycle uses the
/// median of her own completed gaps, and with fewer than two completed cycles
/// there is no length to use, so the open cycle contributes nothing rather
/// than a guess. A date more than 1.5 cycles past its start is a lapse in
/// logging, not a four-week luteal phase — it stops counting.
List<bool> lutealFlags(List<String> dates, List<String> cycleStartDates) {
  final out = List<bool>.filled(dates.length, false);
  DateTime? day(String s) => _day(s);
  final starts = <DateTime>[
    for (final s in cycleStartDates) ?day(s),
  ]..sort();
  if (starts.isEmpty) return out;

  final gaps = <double>[
    for (var i = 1; i < starts.length; i++)
      starts[i].difference(starts[i - 1]).inDays.toDouble(),
  ].where((g) => g >= 15 && g <= 60).toList();
  final medianGap = _median(gaps);

  for (var i = 0; i < dates.length; i++) {
    final d = day(dates[i]);
    if (d == null) continue;
    var si = -1;
    for (var k = 0; k < starts.length; k++) {
      if (starts[k].isAfter(d)) break;
      si = k;
    }
    if (si < 0) continue;
    final elapsed = d.difference(starts[si]).inDays;
    final len = si + 1 < starts.length
        ? starts[si + 1].difference(starts[si]).inDays.toDouble()
        : medianGap;
    if (len == null || len < 15) continue;
    if (elapsed > 1.5 * len) continue;
    if (elapsed >= len / 2) out[i] = true;
  }
  return out;
}

/// The tags/metrics of the journal day whose BEHAVIOURS land on the night
/// labeled [date]: behaviours consumed during the day (alcohol, caffeine, a
/// late meal, a workout, travel, a vaccination) affect the night that follows,
/// so the journal day is the calendar day before the night's label (the same
/// +1 lag `kJournalFieldLagDays` assigns in journal_fields.dart).
List<String> _tagsForNight(
  String date,
  Map<String, List<String>> journalTagsByDate,
) {
  final prev = dayLabelBefore(date, 1);
  final tags = <String>[];
  if (prev != null) tags.addAll(journalTagsByDate[prev] ?? const []);
  // Retrospective entries describe this night itself.
  tags.addAll(journalTagsByDate[date] ?? const []);
  return tags;
}

List<num?>? _metricForNight(
  String field,
  String date,
  Map<String, Map<String, List<num?>>> journalMetricsByDate,
) {
  final prev = dayLabelBefore(date, 1);
  final prevMetrics = prev == null ? null : journalMetricsByDate[prev];
  final cur = journalMetricsByDate[date];
  return (prevMetrics != null ? prevMetrics[field] : null) ??
      (cur != null ? cur[field] : null);
}

/// True when the journal day before [date] holds a 'vaccinated' entry and
/// [date] falls inside the 48–72 h mask window (the next
/// [kVaccinationMaskNights] nights).
bool _vaccinationActive(
  String date,
  Map<String, List<String>> journalTagsByDate,
) {
  for (var k = 1; k <= kVaccinationMaskNights; k++) {
    final d = dayLabelBefore(date, k);
    if (d != null && (journalTagsByDate[d]?.contains('vaccinated') ?? false)) {
      return true;
    }
  }
  return false;
}

/// True when a 'travel' entry lands within the last [kTravelMaskNights] days.
bool _travelActive(String date, Map<String, List<String>> journalTagsByDate) {
  for (var k = 1; k <= kTravelMaskNights; k++) {
    final d = dayLabelBefore(date, k);
    if (d != null && (journalTagsByDate[d]?.contains('travel') ?? false)) {
      return true;
    }
  }
  return false;
}

/// Build the per-night context residuals and the calibration block.
///
/// [dates] oldest-first labels; [unsettled]/[rhr]/[rmssd]/[resp]/[tempAlert]/
/// [strain]/[tstMin] are parallel per-day series (`tempAlert` is the
/// ambient-filtered raw nightly skin-temp mean the temp flag reads).
/// [journalTagsByDate] maps a day label to its tag list; [journalMetricsByDate]
/// maps a day label to `{field: [value, atMinuteOfDay?]}`.
ContextResiduals buildContextResiduals({
  required List<String> dates,
  required List<bool> unsettled,
  required List<double?> rhr,
  required List<double?> rmssd,
  required List<double?> resp,
  required List<double?> tempAlert,
  required List<double?> strain,
  required List<double?> tstMin,
  Map<String, List<String>> journalTagsByDate = const {},
  Map<String, Map<String, List<num?>>> journalMetricsByDate = const {},
  List<String> cycleStartDates = const [],
  // PR 4: per-day workout-derived signals (workout_signals.dart), keyed by
  // day label with numeric keys 'hrr_bpm' / 'volume_kg'. Absent → no offset,
  // byte-for-byte as before.
  Map<String, Map<String, double>> workoutsByDate = const {},
  int windowDays = kCalibrationWindowDays,
}) {
  final n = dates.length;
  double? at(List<double?> xs, int i) =>
      (i < 0 || i >= xs.length) ? null : xs[i];

  // Trailing-window robust stats PER SIGNAL, evaluated strictly BEFORE the
  // night (a night must never be masked by its own deviation) and bounded by
  // [windowDays] of calendar days.
  List<double> windowBefore(int i, List<double?> series) {
    final d = _day(dates[i]);
    final out = <double>[];
    if (d == null) return out;
    for (var j = 0; j < i; j++) {
      final v = series[j];
      if (v == null || !v.isFinite) continue;
      final dj = _day(dates[j]);
      if (dj == null) continue;
      if (calendarDaysBetween(dj, d) > windowDays) continue;
      out.add(v);
    }
    return out;
  }

  final luteal = lutealFlags(dates, cycleStartDates);

  // lnRMSSD window per night (HRV context is computed in the log domain —
  // day-to-day RMSSD is skewed and noisy, Plews et al. IJSPP 2013 — then
  // converted back to a ms-domain offset against the trailing RMSSD median).
  final lnRmssd = <double?>[
    for (var i = 0; i < n; i++)
      (rmssd[i] != null && rmssd[i]! > 0) ? math.log(rmssd[i]!) : null,
  ];

  // Personal sleep need: median of the trailing nights' TST (the sleep-debt
  // engine's OSD is computed later in the same bundle; this keeps the context
  // model self-contained and honest — below 7 nights there is no need).
  const minNeedNights = 7;

  // Cycle-stratified offsets, computed PER NIGHT over the trailing window:
  // the empirical median difference between this user's luteal and non-luteal
  // nights, capped in z units via [scale]. Only with enough luteal nights.
  double? cycleOffset(int i, List<double?> series, double? scale) {
    if (!luteal[i] || cycleStartDates.isEmpty) return null;
    final d = _day(dates[i]);
    if (d == null) return null;
    final lutVals = <double>[], nonVals = <double>[];
    for (var j = 0; j < i; j++) {
      final v = series[j];
      if (v == null || !v.isFinite) continue;
      final dj = _day(dates[j]);
      if (dj == null || calendarDaysBetween(dj, d) > windowDays) continue;
      (luteal[j] ? lutVals : nonVals).add(v);
    }
    if (lutVals.length < kMinLutealNightsForOffset || nonVals.length < 5) {
      return null;
    }
    final off = (_median(lutVals)! - _median(nonVals)!);
    if (scale == null || scale <= 0) return off;
    // Cap in z units so one odd window cannot manufacture a big mask.
    final zCap = kLutealOffsetZCap * scale;
    return off.clamp(-zCap, zCap);
  }

  // date label → row index, for the sleep-debt walk-back.
  final rowOf = <String, int>{for (var i = 0; i < n; i++) dates[i]: i};

  // PR 4: per-day workout signal series (null where no session happened).
  final hrrSeries = <double?>[
    for (var i = 0; i < n; i++) workoutsByDate[dates[i]]?['hrr_bpm']
  ];

  final rhrResidual = List<double?>.filled(n, null);
  final hrvResidual = List<double?>.filled(n, null);
  final respResidual = List<double?>.filled(n, null);
  final tempResidual = List<double?>.filled(n, null);
  final masks = List<List<String>>.filled(n, const []);

  for (var i = 0; i < n; i++) {
    final date = dates[i];
    final active = <String>[];

    // ── trailing robust stats for the z→native conversions ──
    final rhrWin = windowBefore(i, rhr);
    final lnWin = windowBefore(i, lnRmssd);
    final respWin = windowBefore(i, resp);
    final tempWin = windowBefore(i, tempAlert);
    final rhrScale = _robustScale(rhrWin);
    final lnScale = _robustScale(lnWin);
    final respScale = _robustScale(respWin);
    final tempScale = _robustScale(tempWin);
    final rmssdMed = _median(windowBefore(i, rmssd));

    // ── training load: yesterday's strain + 3/7-day rolling means ──
    // The night labeled D follows calendar day D−1, so the load that precedes
    // it is that day's strain (and the days before it).
    final d = _day(date);
    double? strainY, mean3, mean7;
    if (d != null) {
      final w3 = <double>[], w7 = <double>[];
      for (var j = 0; j < i; j++) {
        final s = strain[j];
        if (s == null || !s.isFinite) continue;
        final dj = _day(dates[j]);
        if (dj == null) continue;
        final back = calendarDaysBetween(dj, d);
        if (back == 1) strainY = s;
        if (back >= 1 && back <= 3) w3.add(s);
        if (back >= 1 && back <= 7) w7.add(s);
      }
      if (strainY != null) active.add('load');
      mean3 = w3.isEmpty ? null : w3.reduce((a, b) => a + b) / w3.length;
      mean7 = w7.isEmpty ? null : w7.reduce((a, b) => a + b) / w7.length;
    }

    // ── cumulative sleep debt: the night itself + the two before it, vs the
    // personal need (trailing median TST). One short night is expected noise;
    // a run of them is context. ──
    final needWin = windowBefore(i, tstMin);
    final need = needWin.length >= minNeedNights ? _median(needWin) : null;
    double? debt;
    if (need != null && d != null) {
      var acc = 0.0;
      for (var k = 0; k <= 2; k++) {
        final dd = dayLabelBefore(date, k);
        if (dd == null) continue;
        // tst of the row labeled dd (k = 0 is tonight's own row).
        final idx = rowOf[dd];
        final t = idx != null ? at(tstMin, idx) : null;
        if (t != null && t.isFinite) acc += math.max(0, need - t);
      }
      if (acc > 0) {
        debt = acc;
        active.add('sleep_debt');
      }
    }

    // ── journal context for the night (behaviours land on the next night) ──
    final tags = _tagsForNight(date, journalTagsByDate);
    final alcohol = _metricForNight('alcohol_units', date, journalMetricsByDate);
    final alcoholUnits =
        alcohol != null && alcohol.isNotEmpty && alcohol[0] is num
            ? (alcohol[0] as num).toDouble()
            : (tags.contains('alcohol') ? 1.0 : 0.0);
    if (alcoholUnits > 0) active.add('alcohol');
    final caffeine =
        _metricForNight('caffeine_mg', date, journalMetricsByDate);
    final caffeineLate = caffeine != null &&
        caffeine.isNotEmpty &&
        caffeine[0] is num &&
        (caffeine[0] as num).toDouble() >= 200 &&
        caffeine.length > 1 &&
        caffeine[1] is num &&
        (caffeine[1] as num).toDouble() >= 16 * 60;
    if (caffeineLate || tags.contains('late meal')) {
      active.add(caffeineLate ? 'late caffeine' : 'late meal');
    }
    final vaccination = _vaccinationActive(date, journalTagsByDate);
    if (vaccination) active.add('vaccination');
    final travel = _travelActive(date, journalTagsByDate);
    if (travel) active.add('travel');
    final sick = tags.contains('sick');
    if (sick) active.add('sick');

    // ── expected offsets ──
    var offRhr = 0.0;
    if (strainY != null) offRhr += kRhrBpmPerStrainYesterday * strainY;
    if (mean3 != null) offRhr += kRhrBpmPerStrain3 * mean3;
    if (mean7 != null) offRhr += kRhrBpmPerStrain7 * mean7;
    if (debt != null) offRhr += kRhrBpmPerSleepDebtMin * debt;
    if (alcoholUnits > 0) {
      offRhr += math.min(
        kAlcoholRhrBpmCap,
        kAlcoholRhrBpmPerUnit * alcoholUnits,
      );
    }
    if (caffeineLate) offRhr += kLateCaffeineRhrBpm;
    if (tags.contains('late meal')) offRhr += kLateMealRhrBpm;
    if (vaccination && rhrScale != null) offRhr += kVaccinationRhrZ * rhrScale;
    if (travel && rhrScale != null) offRhr += kTravelRhrZ * rhrScale;
    if (sick && rhrScale != null) offRhr += kSickRhrZ * rhrScale;
    // Empirical luteal RHR offset (cycle-stratified baseline adjustment).
    final lutRhr = cycleOffset(i, rhr, rhrScale);
    if (lutRhr != null) {
      offRhr += lutRhr;
      active.add('luteal');
    }

    var offLn = 0.0; // negative = expected suppression
    if (strainY != null) offLn -= kLnHrvPerStrainYesterday * strainY;
    if (mean3 != null) offLn -= kLnHrvPerStrain3 * mean3;
    if (mean7 != null) offLn -= kLnHrvPerStrain7 * mean7;
    if (debt != null) offLn -= kLnHrvPerSleepDebtMin * debt;
    if (alcoholUnits > 0) {
      offLn -= math.min(
        kAlcoholLnHrvCap,
        kAlcoholLnHrvPerUnit * alcoholUnits,
      );
    }
    if (caffeineLate) offLn -= kLateCaffeineLnHrv;
    if (tags.contains('late meal')) offLn -= kLateMealLnHrv;
    if (vaccination && lnScale != null) offLn -= kVaccinationLnHrvZ * lnScale;
    if (travel && lnScale != null) offLn -= kTravelLnHrvZ * lnScale;
    if (sick && lnScale != null) offLn -= kSickLnHrvZ * lnScale;
    final lutLn = cycleOffset(i, lnRmssd, lnScale);
    if (lutLn != null) offLn += lutLn;

    // ── workout-derived context (PR 4): YESTERDAY's session HRR and strength
    // volume are expected to move tonight's HRV/RHR — a poor HRR after a hard
    // session is recovery, not an illness signal. Absent inputs → offset 0.
    double? hrrY, volY;
    if (d != null) {
      final prev = dayLabelBefore(date, 1);
      final w = prev == null ? null : workoutsByDate[prev];
      if (w != null) {
        hrrY = w['hrr_bpm'];
        volY = w['volume_kg'];
      }
    }
    if (hrrY != null) {
      final hrrWin = windowBefore(i, hrrSeries);
      final hrrBase = hrrWin.length >= 7 ? _median(hrrWin) : null;
      if (hrrBase != null && hrrY < hrrBase - kHrrPoorDeltaBpm) {
        final short = hrrBase - hrrY;
        offLn -= math.min(kHrrLnCap, kLnHrvPerHrrPoorBpm * short);
        offRhr += math.min(kHrrRhrCapBpm, kRhrBpmPerHrrPoorBpm * short);
        active.add('workout recovery');
      }
    }
    if (volY != null && volY > 0) {
      offLn -= math.min(kVolumeLnCap, kLnHrvPerVolumeKg * volY);
      offRhr += math.min(kVolumeRhrCapBpm, kRhrBpmPerVolumeKg * volY);
      active.add('volume');
    }

    var offRespZ = 0.0;
    if (vaccination) offRespZ += kVaccinationRespZ;
    var offTempZ = 0.0;
    if (vaccination) offTempZ += kVaccinationTempZ;
    if (sick) offTempZ += kSickTempZ;
    final lutTemp = cycleOffset(i, tempAlert, tempScale);
    if (lutTemp != null && tempScale != null) {
      offTempZ += lutTemp / tempScale;
      if (!active.contains('luteal')) active.add('luteal');
    }

    // ── residuals: raw − expected. Exactly the raw value when nothing was
    // subtracted (offset 0), so no-context nights are untouched. ──
    final r = at(rhr, i);
    if (r != null && !unsettled[i]) rhrResidual[i] = r - offRhr;
    final h = at(rmssd, i);
    if (h != null && !unsettled[i]) {
      // HRV context is computed in the ln domain, then converted to a ms
      // offset anchored on the trailing RMSSD median: expected =
      // med·exp(offLn), so the value the detector should see is
      // h − med·(exp(offLn) − 1). exp(0) = 1 ⇒ offset exactly 0 with no
      // context (byte-for-byte the raw value); a suppressed night
      // (offLn < 0) reads as its expected value, not as a drop.
      // No median yet (first nights) ⇒ the raw value, unmasked — never null
      // just because the offset could not be scaled.
      hrvResidual[i] = (rmssdMed != null && offLn != 0)
          ? h - rmssdMed * (math.exp(offLn) - 1)
          : h;
    }
    final sp = at(resp, i);
    if (sp != null && !unsettled[i]) {
      respResidual[i] = respScale != null && offRespZ != 0
          ? sp - offRespZ * respScale
          : sp;
    }
    final t = at(tempAlert, i);
    if (t != null && !unsettled[i]) {
      tempResidual[i] = tempScale != null && offTempZ != 0
          ? t - offTempZ * tempScale
          : t;
    }
    masks[i] = active;
  }

  // ── calibration block (Layer 1) ──
  // Valid nights = settled rows that actually carry a nightly RHR, counted in
  // the trailing [windowDays] of CALENDAR days — never calendar days alone,
  // and never a night that was not measured (null stays null).
  final last = n > 0 ? _day(dates[n - 1]) : null;
  var valid = 0;
  final validDates = <DateTime>[];
  final sigCount = <String, int>{'rhr': 0, 'hrv': 0, 'resp': 0, 'temp': 0};
  if (last != null) {
    for (var i = 0; i < n; i++) {
      if (unsettled[i]) continue;
      final d = _day(dates[i]);
      if (d == null || calendarDaysBetween(d, last) > windowDays) continue;
      if (at(rhr, i) != null) {
        valid++;
        validDates.add(d);
      }
      if (at(rhr, i) != null) sigCount['rhr'] = sigCount['rhr']! + 1;
      if (at(rmssd, i) != null) sigCount['hrv'] = sigCount['hrv']! + 1;
      if (at(resp, i) != null) sigCount['resp'] = sigCount['resp']! + 1;
      if (at(tempAlert, i) != null) sigCount['temp'] = sigCount['temp']! + 1;
    }
  }
  var stage = valid < kStageCoarseFrom
      ? 0
      : valid < kStageStandardFrom
          ? 1
          : valid < kStageFullFrom
              ? 2
              : 3;
  // Wear-gap rule: a gap longer than [kWearGapDays] between consecutive valid
  // nights (or after the newest one) drops ONE stage — partial recalibration,
  // the stale baseline kept as a prior, never a hard reset.
  var maxGap = 0;
  for (var k = 1; k < validDates.length; k++) {
    final g = calendarDaysBetween(validDates[k - 1], validDates[k]);
    if (g > maxGap) maxGap = g;
  }
  if (last != null && validDates.isNotEmpty) {
    final trailing = calendarDaysBetween(validDates.last, last);
    if (trailing > maxGap) maxGap = trailing;
  }
  final gapDrop = maxGap > kWearGapDays;
  if (gapDrop && stage > 0) stage -= 1;

  final calibration = <String, dynamic>{
    'model': 'context_residual_v1',
    'window_days': windowDays,
    'valid_nights': valid,
    'stage': stage,
    'stage_label': kCalibrationStageLabels[stage],
    'max_gap_days': maxGap,
    'gap_drop': gapDrop,
    'signals': sigCount,
    'cycle_aware': cycleStartDates.isNotEmpty,
  };

  return ContextResiduals(
    rhrResidual: rhrResidual,
    hrvResidual: hrvResidual,
    respResidual: respResidual,
    tempResidual: tempResidual,
    masks: masks,
    calibration: calibration,
  );
}
