// step_calibration_fit.dart — pure policy for calibrating the strap's LIVE
// 100 Hz pedometer per user and per activity category.
//
// WHERE THE COUNTER LIVES. Not here. The counter is `pedometer()` /
// `livePedometer()` in analytics (`onehz/motion/steps.dart`), fed from the live
// IMU stream that `edge` already ingests (`frameAccel`: gen5 0x2B, gen4 0x33 /
// R10) and banked as `live_coverage.source = 'strap_100hz'`. This file only
// turns a supervised calibration walk into numbers that counter is configured
// with — nothing here touches BLE, a clock or the disk, and NOTHING is written
// to the strap. Everything below is a value the phone keeps.
//
// WHY A CALIBRATION, AND WHAT IT MAY CLAIM. Analytics' own `StepParams.gain`
// docstring asks for exactly this: "A real strap on a real wrist may still need
// trimming — that is what this knob is for. Measure it against ground truth, per
// user, and store it with the user; never bake a population constant back in
// here." On clean synthetic gait the raw count is already exact (raw/truth 1.00
// from 60 to 180 spm), so the gain corrects the RESIDUAL a real wrist adds —
// placement, tightness, arm-swing style — not a defect in the detector. Expect
// values near 1.0, and never a population constant.
//
// TWO KINDS OF CALIBRATION, AND THE SECOND IS THE ONE THAT PAYS.
//
//   * POSITIVE (slow / brisk / jog): the walk produces N real steps and the
//     detector reports some other number over the same span. The correction is
//     a SCALE — `gain = truth / raw` — because the count is real, only its size
//     is wrong.
//
//   * NEGATIVE (everyday: carrying, lifting, moving things around a room): the
//     detector reports a count and the TRUE step count is ~0, because the peaks
//     it counted were arm work, not gait. There is no scale that fixes this:
//     `0 / raw` is 0, and a gain of 0 would credit nothing everywhere. What the
//     run teaches instead is a BOUNDARY — what this wearer's non-gait movement
//     looks like to this sensor — so windows matching it are credited nothing.
//
// The negative run is the one that addresses OVER-counting, which is the
// expensive error: `live_step_runs.dart` records the owner's own measurement of
// rhythmic arm work scored as gait (+199.5%, 217 true steps read as 650). A
// miss costs a walk; a fabricated step corrupts the day.
//
// HONEST LIMIT. Analytics states its own ceiling plainly: "Every independent
// free-living wrist evaluation puts peak detection between 60% and 230% error."
// Nothing here lifts that. It trims a known bias per wearer and refuses one
// measured class of false movement. It does not turn a wrist into a pedometer,
// and no copy built on this may imply it does.
//
// PURE Dart — no I/O, no clock, no protocol import, plain values in and out.

/// The four calibration categories. `everyday` is the negative one; see the
/// file header for why it cannot be a scale factor.
enum StepCategory {
  slow,
  brisk,
  jog,
  everyday;

  /// Stable storage key. Persisted values are matched by NAME, so a reordered
  /// enum cannot silently reattach a stored gain to another category.
  String get key => switch (this) {
        StepCategory.slow => 'slow',
        StepCategory.brisk => 'brisk',
        StepCategory.jog => 'jog',
        StepCategory.everyday => 'everyday',
      };

  /// Null for an unknown key; never a silent fallback to a real category.
  static StepCategory? parse(Object? v) => switch (v) {
        'slow' => StepCategory.slow,
        'brisk' => StepCategory.brisk,
        'jog' => StepCategory.jog,
        'everyday' => StepCategory.everyday,
        _ => null,
      };

  bool get isPositive => this != StepCategory.everyday;
}

/// One supervised calibration run: the wearer counts their own steps, the
/// detector counts what it saw, and the features are what the run looked like.
///
/// [expectedSteps] is the ONLY ground truth in this feature and it comes from
/// the user, which is why a single admitted run is enough to mark a category
/// calibrated — unlike `lib/data/step_calibration.dart`, whose days are fitted
/// against a phone and therefore need three of them plus a prior.
class StepCalibrationRun {
  const StepCalibrationRun({
    required this.category,
    required this.expectedSteps,
    required this.rawSteps,
    required this.cadenceSpm,
    required this.peakToPeakG,
    required this.confidence,
  });

  final StepCategory category;
  final int expectedSteps;
  final int rawSteps;

  /// From `PedometerResult.cadenceSpm` over the run's span.
  final double cadenceSpm;

  /// `PedometerResult.peakToPeakG` — median stride amplitude, the motion
  /// strength. Carrying and lifting push this above a walk's.
  final double peakToPeakG;

  /// `PedometerResult.confidence` — amplitude AND rhythm regularity, 0..1.
  /// This is the discriminator the negative run leans on: rhythmic arm work
  /// scores high, lifting and carrying score low.
  final double confidence;
}

/// A run smaller than this cannot carry a ratio: the noise in a 40-step walk's
/// count is larger than the bias it is meant to measure.
const int kStepCalMinExpectedSteps = 50;

/// The detector claiming almost nothing over a supervised walk is a signal the
/// run failed (band not worn, walk done off-wrist, stream dropped), not a
/// measurement of a 20x gain.
const int kStepCalMinRawSteps = 20;

/// A learned gain outside this band means the RUN went wrong, not that the
/// counter is that far off — same reasoning as `kStepFactorMin/Max`.
const double kStepGainMin = 0.5;
const double kStepGainMax = 2.0;

// NO PRIOR WEIGHT HERE, AND THAT IS A DELIBERATE DEVIATION from
// `lib/data/step_calibration.dart`, which blends three pseudo-days of factor 1.0
// into its fit.
//
// That prior exists because ITS reference is INFERRED: a day is admitted when
// the phone counted alongside the band, and a phone in a drawer is a bad day
// dressed as a measurement. Shrinking toward 1.0 stops one bad day from moving
// the factor.
//
// This fit's reference is SUPERVISED: the wearer counts their own 100 steps, on
// purpose, having been told to walk evenly. That is a different class of
// evidence, and the guards that remain — admissibility, and the clamp below —
// already bound the damage a single bad run can do. A prior on top of them cost
// more than it bought: blending 3 pseudo-runs of 1.0 meant a first calibration
// of 100-said/110-seen resolved to 0.977 and corrected barely a fifth of the
// bias the wearer had just measured. A user who walks their calibration walk
// and then sees no change has been told the feature does not work.
//
// Repeated runs still converge: the estimator is a ratio of SUMS, so later runs
// outweigh earlier ones by the steps they carry. That is evidence weighting, not
// forgetting, and it needs no invented constant.

/// Bump when the fit changes so stored profiles are ignored rather than
/// misread. Distinct namespace from `kStepCalibrationVersion` in
/// `lib/data/step_calibration.dart` (the band counter's factor) — two different
/// models must never be able to overwrite each other's stored value.
const int kLiveStepGainVersion = 100;

/// Cadence search window for a category band, as a fraction of the fitted
/// centre. Wide enough to absorb stride variation inside one category, narrow
/// enough that neighbouring categories do not overlap.
const double kCategoryBandSpread = 0.20;

/// Hard floor on band width (spm). A short run's median is not precise enough
/// to define a 2 spm window, and a band narrower than the wearer's own stride
/// variation would reject their real walking.
const double kCategoryBandMinWidthSpm = 20.0;

/// Physiological bounds from AN-2554, in spm: 0.5–5 steps/s. Bands are clamped
/// here so a mis-entered run cannot produce a band outside human gait.
const double kGaitCadenceMinSpm = 30.0;
const double kGaitCadenceMaxSpm = 300.0;

/// Why a run was refused. Every rejection is a claim about the RUN, and the
/// caller must show it rather than silently discarding a walk the user just did.
enum StepRunRejection {
  expectedTooSmall,
  rawTooSmall,
  nonFiniteFeature,
  rawExceedsExpectedByTooMuch,
}

/// Null when the run may be used to fit; otherwise why it may not.
StepRunRejection? stepRunRejection(StepCalibrationRun r) {
  if (!r.cadenceSpm.isFinite || !r.peakToPeakG.isFinite || !r.confidence.isFinite) {
    return StepRunRejection.nonFiniteFeature;
  }
  if (r.expectedSteps < kStepCalMinExpectedSteps) {
    return StepRunRejection.expectedTooSmall;
  }
  if (r.rawSteps < kStepCalMinRawSteps) {
    return StepRunRejection.rawTooSmall;
  }
  // `raw / expected` is clamped to kStepGainMax, so a run beyond the clamp is
  // not a measurement of the gain — it is a measurement of something else.
  if (r.rawSteps > (r.expectedSteps * kStepGainMax).ceil()) {
    return StepRunRejection.rawExceedsExpectedByTooMuch;
  }
  return null;
}

/// A fitted per-user, per-category correction for the live 100 Hz pedometer.
class LiveStepGainProfile {
  const LiveStepGainProfile({
    required this.version,
    required this.category,
    required this.gain,
    required this.nRuns,
    required this.updatedAt,
  });

  final int version;
  final StepCategory category;

  /// Clamped to [kStepGainMin, kStepGainMax]; exactly 1.0 when nothing was
  /// learned. 1.0 is not "unset" — it is the shipped behaviour, which is why an
  /// uncalibrated category and a fitted 1.0 behave identically and correctly.
  final double gain;

  /// Admitted runs behind [gain]; 0 = no calibration, use the default.
  final int nRuns;
  final DateTime updatedAt;

  /// A category is calibrated as soon as one supervised run is admitted: the
  /// ground truth is the wearer's own count, not an inferred reference.
  bool get isCalibrated => nRuns > 0;

  /// The profile every uncalibrated category resolves to. `gain` 1.0 is the
  /// value analytics ships as its default.
  static LiveStepGainProfile uncalibrated(
    StepCategory category,
    DateTime? now,
  ) =>
      LiveStepGainProfile(
        version: kLiveStepGainVersion,
        category: category,
        gain: 1.0,
        nRuns: 0,
        updatedAt: now ?? DateTime.fromMillisecondsSinceEpoch(0),
      );

  Map<String, dynamic> toJson() => {
        'v': version,
        'cat': category.key,
        'gain': gain,
        'n': nRuns,
        'ts': updatedAt.toIso8601String(),
      };

  /// Defensive: a stored profile is user data that may predate a field, and a
  /// malformed one must yield null (fall back to default behaviour) rather than
  /// throw inside the derive path or, worse, load as a fabricated gain.
  static LiveStepGainProfile? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final category = StepCategory.parse(raw['cat']);
    if (category == null) return null;
    final version = raw['v'];
    if (version is! int || version != kLiveStepGainVersion) return null;
    final gain = raw['gain'];
    if (gain is! num || !gain.isFinite) return null;
    if (gain < kStepGainMin || gain > kStepGainMax) return null;
    final nRuns = raw['n'];
    if (nRuns is! int || nRuns < 0) return null;
    final ts = raw['ts'];
    final updatedAt = ts is String ? DateTime.tryParse(ts) : null;
    if (updatedAt == null) return null;
    return LiveStepGainProfile(
      version: version,
      category: category,
      gain: gain.toDouble(),
      nRuns: nRuns,
      updatedAt: updatedAt,
    );
  }
}

/// Fit the positive-category gain over every admitted run.
///
/// Ratio of SUMS, not the mean of per-run ratios: each run is weighted by the
/// evidence it carries, so a 500-step walk is not cancelled out by a 60-step one
/// — the same construction as `estimateStepCalibration`.
///
/// `everyday` returns the uncalibrated profile on purpose. It has no scale, and
/// producing one would be a fabricated number with a legitimate-looking shape;
/// its measurement is [EverydayProbe] instead.
LiveStepGainProfile estimateLiveStepGain(
  StepCategory category,
  List<StepCalibrationRun> runs, {
  required DateTime now,
}) {
  final fit = fittedGain(category, runs);
  if (fit == null) return LiveStepGainProfile.uncalibrated(category, now);
  return LiveStepGainProfile(
    version: kLiveStepGainVersion,
    category: category,
    gain: fit.gain,
    nRuns: fit.nRuns,
    updatedAt: now,
  );
}

/// The fitted gain and its evidence, or null when the category has no admitted
/// run. Split out so [creditLiveSteps] can apply the correction without
/// inventing a timestamp to wrap it in a profile.
({double gain, int nRuns})? fittedGain(
  StepCategory category,
  List<StepCalibrationRun> runs,
) {
  if (!category.isPositive) return null;
  final admitted = [
    for (final r in runs)
      if (r.category == category && stepRunRejection(r) == null) r,
  ];
  if (admitted.isEmpty) return null;

  final expected = admitted.fold<int>(0, (a, r) => a + r.expectedSteps);
  final raw = admitted.fold<int>(0, (a, r) => a + r.rawSteps);
  if (raw <= 0 || expected <= 0) return null;

  // Ratio of SUMS, not the mean of per-run ratios: each run is weighted by the
  // evidence it carries, so a 500-step walk is not cancelled out by a 60-step
  // one. Repeated runs then refine the estimate for free — the sum ratio is
  // dominated by whichever runs carried the most steps.
  final ratio = expected / raw;
  return (
    gain: ratio.clamp(kStepGainMin, kStepGainMax),
    nRuns: admitted.length,
  );
}

/// A cadence window a calibrated category owns.
class StepCategoryBand {
  const StepCategoryBand({
    required this.category,
    required this.minSpm,
    required this.maxSpm,
  });

  final StepCategory category;
  final double minSpm;
  final double maxSpm;

  bool contains(double spm) => spm >= minSpm && spm <= maxSpm;
}

/// Band for one positive category from its admitted runs: median cadence, opened
/// by [kCategoryBandSpread] and floored at [kCategoryBandMinWidthSpm].
///
/// The median, not the mean: one run walked at a wrong tempo must not drag the
/// window off the wearer's real cadence. Null when the category has no admitted
/// run — an uncalibrated category owns no window and therefore never claims a
/// minute.
StepCategoryBand? categoryBand(
  StepCategory category,
  List<StepCalibrationRun> runs,
) {
  if (!category.isPositive) return null;
  final cadences = [
    for (final r in runs)
      if (r.category == category && stepRunRejection(r) == null) r.cadenceSpm,
  ]..sort();
  if (cadences.isEmpty) return null;

  final n = cadences.length;
  final median = n.isOdd
      ? cadences[n ~/ 2]
      : (cadences[n ~/ 2 - 1] + cadences[n ~/ 2]) / 2;
  var half = (median * kCategoryBandSpread).clamp(
    kCategoryBandMinWidthSpm / 2,
    kGaitCadenceMaxSpm,
  );
  var lo = median - half;
  var hi = median + half;
  // Clamp to human gait without letting the clamp collapse the band.
  if (lo < kGaitCadenceMinSpm) {
    hi += kGaitCadenceMinSpm - lo;
    lo = kGaitCadenceMinSpm;
  }
  if (hi > kGaitCadenceMaxSpm) {
    lo -= hi - kGaitCadenceMaxSpm;
    hi = kGaitCadenceMaxSpm;
  }
  return StepCategoryBand(
    category: category,
    minSpm: lo < kGaitCadenceMinSpm ? kGaitCadenceMinSpm : lo,
    maxSpm: hi > kGaitCadenceMaxSpm ? kGaitCadenceMaxSpm : hi,
  );
}

/// Which calibrated category owns a live window's cadence.
///
/// Nearest band centre among the calibrated positive categories, but only when
/// the cadence actually lands inside that band. A window between two bands, or
/// outside every calibrated band, belongs to NO category — it falls back to the
/// shipped behaviour rather than being forced into the nearest one, because
/// forcing it would apply a correction measured on a different gait.
StepCategory? categoryForCadence(
  double spm,
  List<StepCalibrationRun> runs,
) {
  if (!spm.isFinite || spm <= 0) return null;
  StepCategoryBand? best;
  var bestDistance = double.infinity;
  for (final c in StepCategory.values) {
    final band = categoryBand(c, runs);
    if (band == null || !band.contains(spm)) continue;
    final distance = (spm - (band.minSpm + band.maxSpm) / 2).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = band;
    }
  }
  return best?.category;
}

/// The negative calibration: what this wearer's non-gait movement looks like.
///
/// A walk has a rhythm. Carrying, lifting and rearranging do not, and analytics
/// already scores exactly that as `PedometerResult.confidence` (amplitude plus
/// rhythm regularity). So the everyday run yields one number — the HIGHEST
/// confidence any of its runs reached — and a live window at or below it is
/// credited nothing.
///
/// The maximum, not the mean, and deliberately so: the boundary must reject
/// every non-gait run the user actually performed, including their most
/// walk-like one. Using a mean would let the worst run through, which is the
/// false positive this whole category exists to stop.
class EverydayProbe {
  const EverydayProbe({
    required this.maxConfidence,
    required this.nRuns,
    required this.updatedAt,
  });

  final double maxConfidence;
  final int nRuns;
  final DateTime updatedAt;

  bool get isCalibrated => nRuns > 0;

  /// A window is refused when it is no more rhythmic than the wearer's own
  /// non-gait movement. Equal counts as refused: the boundary is inclusive on
  /// the rejecting side, because a false step is the error that cannot be
  /// recovered.
  bool refuses(double confidence) => isCalibrated && confidence <= maxConfidence;

  Map<String, dynamic> toJson() => {
        'v': kLiveStepGainVersion,
        'cat': StepCategory.everyday.key,
        'conf': maxConfidence,
        'n': nRuns,
        'ts': updatedAt.toIso8601String(),
      };

  static EverydayProbe? tryParse(Object? raw) {
    if (raw is! Map) return null;
    if (StepCategory.parse(raw['cat']) != StepCategory.everyday) return null;
    if (raw['v'] != kLiveStepGainVersion) return null;
    final conf = raw['conf'];
    if (conf is! num || !conf.isFinite || conf < 0 || conf > 1) return null;
    final nRuns = raw['n'];
    if (nRuns is! int || nRuns < 0) return null;
    final ts = raw['ts'];
    final updatedAt = ts is String ? DateTime.tryParse(ts) : null;
    if (updatedAt == null) return null;
    return EverydayProbe(
      maxConfidence: conf.toDouble(),
      nRuns: nRuns,
      updatedAt: updatedAt,
    );
  }
}

/// Build the negative probe from every admitted `everyday` run, or null when
/// the wearer has not performed one. Null is the shipped behaviour: with no
/// probe, nothing is refused and the counter behaves exactly as it does today.
EverydayProbe? estimateEverydayProbe(
  List<StepCalibrationRun> runs, {
  required DateTime now,
}) {
  final admitted = [
    for (final r in runs)
      if (r.category == StepCategory.everyday && stepRunRejection(r) == null) r,
  ];
  if (admitted.isEmpty) return null;
  var maxConfidence = 0.0;
  for (final r in admitted) {
    if (r.confidence > maxConfidence) maxConfidence = r.confidence;
  }
  return EverydayProbe(
    maxConfidence: maxConfidence,
    nRuns: admitted.length,
    updatedAt: now,
  );
}

/// What a live window's raw count is finally credited as.
class StepCredit {
  const StepCredit({
    required this.creditedSteps,
    required this.rawSteps,
    required this.category,
    required this.gainApplied,
    required this.refusedByEverydayProbe,
  });

  final int creditedSteps;
  final int rawSteps;

  /// Null when no calibrated band owned this window's cadence.
  final StepCategory? category;

  /// The gain actually used — 1.0 for an uncalibrated category, so the caller
  /// can log "no correction applied" without a second lookup.
  final double gainApplied;

  /// True when the negative probe refused the window, so the UI can say WHY a
  /// count of 40 became 0 instead of showing a silent zero.
  final bool refusedByEverydayProbe;
}

/// Apply the calibration to one live window.
///
/// Order matters and is the whole policy:
///   1. the negative probe refuses non-gait movement, because a fabricated step
///      costs more than a missed one;
///   2. otherwise the window's cadence picks a calibrated category, whose gain
///      scales the raw count;
///   3. anything uncalibrated is credited EXACTLY as it is today — raw, gain
///      1.0. The feature must be invisible until the wearer has calibrated.
StepCredit creditLiveSteps({
  required int rawSteps,
  required double cadenceSpm,
  required double confidence,
  required List<StepCalibrationRun> runs,
  EverydayProbe? everydayProbe,
}) {
  if (rawSteps <= 0) {
    return StepCredit(
      creditedSteps: 0,
      rawSteps: rawSteps < 0 ? 0 : rawSteps,
      category: null,
      gainApplied: 1.0,
      refusedByEverydayProbe: false,
    );
  }
  if (everydayProbe?.refuses(confidence) ?? false) {
    return StepCredit(
      creditedSteps: 0,
      rawSteps: rawSteps,
      category: null,
      gainApplied: 1.0,
      refusedByEverydayProbe: true,
    );
  }
  final category = categoryForCadence(cadenceSpm, runs);
  if (category == null) {
    return StepCredit(
      creditedSteps: rawSteps,
      rawSteps: rawSteps,
      category: null,
      gainApplied: 1.0,
      refusedByEverydayProbe: false,
    );
  }
  final fit = fittedGain(category, runs);
  if (fit == null) {
    return StepCredit(
      creditedSteps: rawSteps,
      rawSteps: rawSteps,
      category: category,
      gainApplied: 1.0,
      refusedByEverydayProbe: false,
    );
  }
  final credited = (rawSteps * fit.gain).round();
  // A gain below 1.0 must not be able to manufacture steps, and none may be
  // negative: the clamp mirrors `applyStepCalibration`'s.
  return StepCredit(
    creditedSteps: credited.clamp(0, (rawSteps * kStepGainMax).ceil()),
    rawSteps: rawSteps,
    category: category,
    gainApplied: fit.gain,
    refusedByEverydayProbe: false,
  );
}
