// step_calibration_fit.dart — pure policy for calibrating the strap's LIVE
// 100 Hz pedometer per user and per activity category.
//
// WHERE THE COUNTER LIVES. Not here. The counter is `pedometer()` /
// `livePedometer()` in analytics (`onehz/motion/steps.dart`), fed from the live
// IMU stream `edge` already ingests (`frameAccel`: gen5 0x2B, gen4 0x33 / R10)
// and banked as `live_coverage.source = 'strap_100hz'`. This file only turns a
// calibration routine into numbers that counter is configured with. Nothing
// here touches BLE or the strap: every value stays on the phone, so there is
// nothing a factory reset has to undo.
//
// WHY A CALIBRATION AT ALL. Analytics' own `StepParams.gain` docstring asks for
// it: "A real strap on a real wrist may still need trimming — that is what this
// knob is for. Measure it against ground truth, per user, and store it with the
// user; never bake a population constant back in here." On clean synthetic gait
// the raw count is already exact (raw/truth 1.00 from 60 to 180 spm), so a gain
// corrects the RESIDUAL a real wrist adds. Expect values near 1.0 for gait, and
// never a population constant.
//
// ── TWO CATEGORY FAMILIES, ONE MECHANISM ────────────────────────────────────
//
// Everything below is a SCALE — `gain = truth / raw` — because the wearer
// determined the truth. What differs between the families is the REFERENCE and
// the RANGE, not the maths:
//
//   * GAIT (slow / brisk / jog): the wearer counts their own steps during the
//     calibration walk. `expectedSteps` is that count, and the gain lands near
//     1.0 because the detector is already close on real gait.
//
//   * EVERYDAY (household: carrying, lifting, moving things around a room): the
//     reference is the PHONE's own pedometer over the same span, because nobody
//     can count steps while doing chores. The gain here lands LOW, and that is
//     the point — at the wrist, ordinary arm work out-accelerates walking
//     (stirring ~104 mg, chopping ~139 mg vs walking ~66 mg ENMO), which is why
//     wrist devices emit 22-27 false steps/min during dishes, reaching and
//     driving (O'Connell 2017). A household routine produces mostly false
//     peaks, so the honest correction is a large downward scale.
//
// WHY NOT ZERO. A household routine is not zero steps — the wearer really does
// walk to the next room. Rejecting the window outright would delete those real
// steps, and it would do so precisely where the wearer asked for a number. So
// the everyday gain is floored at [kEverydayGainMin], never 0, and a routine
// that produced no phone-counted steps at all is REFUSED as a calibration run
// (there is then no reference to fit, which is different from a measured zero).
//
// WHY NOT ONE GLOBAL GAIN. The codebase already settled this: "The two errors
// have OPPOSITE sign, so no gain constant corrects both" — the wrist
// over-counts arm work and under-counts slow walking. Splitting the correction
// by cadence family is the whole reason this file exists rather than one number.
//
// DRIVING IS NOT THIS FILE'S JOB. `lib/data/live_coverage_policy.dart` already
// owns it: a phone row confirming a MOTIONLESS hour drops the band credit
// overlapping it, unless the band span's own density already looks like gait
// ([kConfirmedStillMinSpm] = 40 spm, set above the measured 22-27 spm
// false-positive ceiling and below real walking). The everyday gain is a
// backstop on top of that rule, not a replacement.
//
// HONEST LIMIT. Analytics states its own ceiling: "Every independent free-living
// wrist evaluation puts peak detection between 60% and 230% error." Nothing here
// lifts that. It trims a measured bias per wearer and per movement family. It
// does not turn a wrist into a pedometer, and no copy built on this may say it
// did.
//
// PURE Dart — no I/O, no clock, no protocol import, plain values in and out.

/// The four calibration categories. The first three are gait; `everyday` is the
/// household family and is fitted against the phone. See the file header.
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

  /// True for the three foot-locomotion families. `everyday` is NOT gait, but
  /// it is still a scale — see the file header for why it is not a rejection.
  bool get isGait => this != StepCategory.everyday;

  /// The reference a run of this category is fitted against, for the UI to
  /// state plainly rather than implying the wearer counts in both cases.
  bool get referenceIsPhone => this == StepCategory.everyday;
}

/// Where a run's ground truth came from.
enum StepReference {
  /// The wearer counted their own steps during the calibration walk.
  wearerCount,

  /// The phone's own pedometer over the same span. The only usable reference
  /// while doing chores, and a better sensor for this quantity than the wrist —
  /// see `lib/health/phone_pedometer.dart`.
  phonePedometer,
}

/// One supervised calibration run: a routine was performed, the strap's counter
/// saw what it saw, and something independent says how many steps were real.
class StepCalibrationRun {
  const StepCalibrationRun({
    required this.category,
    required this.reference,
    required this.expectedSteps,
    required this.rawSteps,
    required this.cadenceSpm,
    required this.peakToPeakG,
    required this.confidence,
  });

  final StepCategory category;
  final StepReference reference;

  /// Ground truth for this span: the wearer's own count for the gait families,
  /// the phone's pedometer for `everyday`. Never an estimate we invented.
  final int expectedSteps;

  /// `PedometerResult.steps` over the same span — the strap's raw count.
  final int rawSteps;

  /// `PedometerResult.cadenceSpm` over the run's span.
  final double cadenceSpm;

  /// `PedometerResult.peakToPeakG` — median stride amplitude, the motion
  /// strength. Carrying and lifting push this above a walk's.
  final double peakToPeakG;

  /// `PedometerResult.confidence` — amplitude AND rhythm regularity, 0..1.
  final double confidence;
}

/// A run smaller than this cannot carry a ratio: the noise in a 40-step walk's
/// count is larger than the bias it is meant to measure.
const int kStepCalMinExpectedSteps = 50;

/// The detector claiming almost nothing over a supervised routine is evidence
/// the run failed (band not worn, stream dropped), not a measurement of a 20x
/// gain.
const int kStepCalMinRawSteps = 20;

/// Range a GAIT gain may take. Outside it the RUN went wrong, not the counter.
const double kGaitGainMin = 0.5;
const double kGaitGainMax = 2.0;

/// Range an EVERYDAY gain may take, and it is a different axis on purpose.
///
/// The floor is deliberately far below [kGaitGainMin] because a large downward
/// correction is the EXPECTED outcome here, and it is clamped above zero because
/// a household routine contains real steps: the wearer does walk to the next
/// room, and a hard zero would delete those. The ceiling is 1.0 — an everyday
/// gain above 1.0 would claim the wrist UNDER-counts arm work, which contradicts
/// the measured 22-27 false steps/min and would be a licence to inflate.
const double kEverydayGainMin = 0.05;
const double kEverydayGainMax = 1.0;

/// Bump when the fit changes so stored profiles are ignored rather than
/// misread. Distinct namespace from `kStepCalibrationVersion` in
/// `lib/data/step_calibration.dart` (the band counter's factor) — two different
/// models must never be able to overwrite each other's stored value.
const int kLiveStepGainVersion = 100;

/// Cadence search window for a GAIT category band, as a fraction of the fitted
/// centre. Wide enough to absorb stride variation inside one category, narrow
/// enough that neighbouring categories do not overlap.
const double kCategoryBandSpread = 0.20;

/// Hard floor on band width (spm). A short run's median is not precise enough to
/// define a 2 spm window, and a band narrower than the wearer's own stride
/// variation would reject their real walking.
const double kCategoryBandMinWidthSpm = 20.0;

/// Physiological bounds from AN-2554, in spm: 0.5-5 steps/s. Bands are clamped
/// here so a mis-entered run cannot produce a band outside human gait.
const double kGaitCadenceMinSpm = 30.0;
const double kGaitCadenceMaxSpm = 300.0;

/// Why a run was refused. Every rejection is a claim about the RUN, and the
/// caller must show it rather than silently discarding a routine the wearer just
/// performed.
enum StepRunRejection {
  expectedTooSmall,
  rawTooSmall,
  nonFiniteFeature,
  rawExceedsExpectedByTooMuch,
  referenceWrongSource,

  /// An `everyday` run whose reference counted no steps at all. That is not a
  /// measured zero to scale toward — it is the absence of a reference (the phone
  /// was on a table), and fitting a 0.0 gain from it would delete every real
  /// step in every later household window.
  noReferenceSteps,
}

/// Null when the run may be used to fit; otherwise why it may not.
StepRunRejection? stepRunRejection(StepCalibrationRun r) {
  if (!r.cadenceSpm.isFinite ||
      !r.peakToPeakG.isFinite ||
      !r.confidence.isFinite) {
    return StepRunRejection.nonFiniteFeature;
  }
  if (r.category.referenceIsPhone != (r.reference == StepReference.phonePedometer)) {
    return StepRunRejection.referenceWrongSource;
  }
  if (r.rawSteps < kStepCalMinRawSteps) return StepRunRejection.rawTooSmall;

  if (r.category.isGait) {
    if (r.expectedSteps < kStepCalMinExpectedSteps) {
      return StepRunRejection.expectedTooSmall;
    }
    // `raw / expected` is clamped to kGaitGainMax, so a walk beyond the clamp is
    // no longer a measurement of the gain.
    if (r.rawSteps > (r.expectedSteps * kGaitGainMax).ceil()) {
      return StepRunRejection.rawExceedsExpectedByTooMuch;
    }
    return null;
  }

  // EVERYDAY. The band is EXPECTED to see far more than the phone — that is the
  // over-count being measured — so the gait floor and ceiling both invert:
  // a reference of 0 is refused (no reference), and the truth must not exceed
  // what the band saw (that would be an under-count, the opposite family).
  if (r.expectedSteps <= 0) return StepRunRejection.noReferenceSteps;
  if (r.expectedSteps > r.rawSteps) {
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

  /// Clamped to the category's own range: [kGaitGainMin]..[kGaitGainMax] for
  /// gait, [kEverydayGainMin]..[kEverydayGainMax] for everyday. Exactly 1.0 when
  /// nothing was learned — and 1.0 is not "unset", it is the shipped behaviour,
  /// which is why an uncalibrated category and a fitted 1.0 behave identically.
  final double gain;

  /// Admitted runs behind [gain]; 0 = no calibration, use the default.
  final int nRuns;
  final DateTime updatedAt;

  /// A category is calibrated as soon as one admitted run exists — the reference
  /// is either the wearer's own count or a vendor pedometer, not an inference.
  bool get isCalibrated => nRuns > 0;

  /// The profile every uncalibrated category resolves to. `gain` 1.0 is what
  /// analytics ships as its default.
  static LiveStepGainProfile uncalibrated(StepCategory category, DateTime? now) =>
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
    if (raw['v'] != kLiveStepGainVersion) return null;
    final gain = raw['gain'];
    if (gain is! num || !gain.isFinite) return null;
    final lo = gainFloor(category);
    final hi = gainCeiling(category);
    if (gain < lo || gain > hi) return null;
    final nRuns = raw['n'];
    if (nRuns is! int || nRuns < 0) return null;
    final ts = raw['ts'];
    final updatedAt = ts is String ? DateTime.tryParse(ts) : null;
    if (updatedAt == null) return null;
    return LiveStepGainProfile(
      version: kLiveStepGainVersion,
      category: category,
      gain: gain.toDouble(),
      nRuns: nRuns,
      updatedAt: updatedAt,
    );
  }
}

/// Lowest gain the category may hold. `everyday` is allowed far below 1.0
/// because a large downward correction is its expected outcome — see the file
/// header for why it is nonetheless never 0.
double gainFloor(StepCategory category) =>
    category.isGait ? kGaitGainMin : kEverydayGainMin;

/// Highest gain the category may hold.
double gainCeiling(StepCategory category) =>
    category.isGait ? kGaitGainMax : kEverydayGainMax;

/// The fitted gain and its evidence, or null when the category has no admitted
/// run. Split out so [creditLiveSteps] can apply a correction without inventing
/// a timestamp to wrap in a profile.
({double gain, int nRuns})? fittedGain(
  StepCategory category,
  List<StepCalibrationRun> runs,
) {
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
  // one. Repeated runs then refine the estimate for free.
  //
  // NO PRIOR WEIGHT, deliberately deviating from `lib/data/step_calibration.dart`
  // (which blends three pseudo-days of factor 1.0). That prior guards an
  // INFERRED reference — a day counts only when the phone happened to be
  // alongside. This fit's reference is either the wearer's own supervised count
  // or the phone's pedometer over the SAME span. Admissibility and the clamp
  // already bound a bad run, and the prior cost more than it bought: blending
  // three pseudo-runs of 1.0 meant a first 100-said/110-seen calibration
  // resolved to 0.977 and corrected a fifth of the bias just measured. A wearer
  // who walks their calibration walk and sees nothing change has been told the
  // feature does not work.
  final ratio = expected / raw;
  return (
    gain: ratio.clamp(gainFloor(category), gainCeiling(category)),
    nRuns: admitted.length,
  );
}

/// Fit one category's gain. The `now` parameter exists only so the stored
/// `updatedAt` is supplied by the caller, keeping this function clock-free.
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

/// A cadence window a calibrated GAIT category owns.
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

/// Band for one gait category from its admitted runs: median cadence, opened by
/// [kCategoryBandSpread] and floored at [kCategoryBandMinWidthSpm].
///
/// The median, not the mean: one run walked at a wrong tempo must not drag the
/// window off the wearer's real cadence. Null for `everyday` (which has no gait
/// band by definition) and for an uncalibrated category.
StepCategoryBand? categoryBand(
  StepCategory category,
  List<StepCalibrationRun> runs,
) {
  if (!category.isGait) return null;
  final cadences = [
    for (final r in runs)
      if (r.category == category && stepRunRejection(r) == null) r.cadenceSpm,
  ]..sort();
  if (cadences.isEmpty) return null;

  final n = cadences.length;
  final median =
      n.isOdd ? cadences[n ~/ 2] : (cadences[n ~/ 2 - 1] + cadences[n ~/ 2]) / 2;
  final half = (median * kCategoryBandSpread)
      .clamp(kCategoryBandMinWidthSpm / 2, kGaitCadenceMaxSpm);
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

/// Which calibrated GAIT category owns a live window's cadence.
///
/// Nearest band centre among the calibrated gait categories, but only when the
/// cadence actually lands inside that band. A window between two bands, or
/// outside every calibrated band, belongs to NO gait category — it falls
/// through to the everyday gain rather than being forced into the nearest gait
/// band, because forcing it would apply a correction measured on a different
/// kind of movement.
StepCategory? gaitCategoryForCadence(
  double spm,
  List<StepCalibrationRun> runs,
) {
  if (!spm.isFinite || spm <= 0) return null;
  StepCategory? best;
  var bestDistance = double.infinity;
  for (final c in StepCategory.values) {
    final band = categoryBand(c, runs);
    if (band == null || !band.contains(spm)) continue;
    final distance = (spm - (band.minSpm + band.maxSpm) / 2).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = c;
    }
  }
  return best;
}

/// What a live window's raw count is finally credited as.
class StepCredit {
  const StepCredit({
    required this.creditedSteps,
    required this.rawSteps,
    required this.category,
    required this.gainApplied,
    required this.calibrated,
  });

  final int creditedSteps;
  final int rawSteps;

  /// The family the correction came from. Null only when nothing was applied.
  final StepCategory? category;

  /// The gain actually used — 1.0 when nothing was calibrated, so a caller can
  /// log "no correction applied" without a second lookup.
  final double gainApplied;

  /// False when the wearer has not calibrated this family: the window is
  /// credited EXACTLY as it is today. The feature must be invisible until the
  /// wearer has calibrated.
  final bool calibrated;
}

/// Apply the calibration to one live window.
///
/// The mapping is the whole policy:
///   1. a window whose cadence falls in a calibrated gait band uses that band's
///      gain (slow / brisk / jog);
///   2. every other window — including household arm work, which has no gait
///      cadence at all — uses the everyday gain;
///   3. anything uncalibrated is credited exactly as today, raw with gain 1.0.
///
/// Driving is NOT handled here. `lib/data/live_coverage_policy.dart` already
/// drops band credit that overlaps a phone-confirmed motionless hour unless the
/// span's own density looks like gait; the everyday gain only damps what
/// survives that rule.
StepCredit creditLiveSteps({
  required int rawSteps,
  required double cadenceSpm,
  required List<StepCalibrationRun> runs,
}) {
  if (rawSteps <= 0) {
    return StepCredit(
      creditedSteps: 0,
      rawSteps: rawSteps < 0 ? 0 : rawSteps,
      category: null,
      gainApplied: 1.0,
      calibrated: false,
    );
  }

  final gait = gaitCategoryForCadence(cadenceSpm, runs);
  // A gait window with an uncalibrated band falls through to everyday, whose
  // gain is capped at 1.0 — so it can never inflate, only damp.
  final family = gait ?? StepCategory.everyday;

  final fit = fittedGain(family, runs);
  if (fit == null) {
    return StepCredit(
      creditedSteps: rawSteps,
      rawSteps: rawSteps,
      category: null,
      gainApplied: 1.0,
      calibrated: false,
    );
  }

  final credited = (rawSteps * fit.gain).round();
  // A gain below 1.0 must not be able to manufacture steps, and none may be
  // negative: the clamp mirrors `applyStepCalibration`'s.
  return StepCredit(
    creditedSteps: credited.clamp(0, (rawSteps * kGaitGainMax).ceil()),
    rawSteps: rawSteps,
    category: family,
    gainApplied: fit.gain,
    calibrated: true,
  );
}
