// step_calibration.dart — pure, I/O-free policy for wearing-location aware
// calibration of the gen5 on-chip step counter. Nothing here touches BLE,
// the DB, Flutter or the clock: callers hand in observed facts and read back
// a correction. Every branch is unit-testable.
//
// WHY A USER-SET WEARING LOCATION EXISTS AT ALL
// The WHOOP ships on the wrist and the upper arm (bicep band), and the arm is
// a different sensor for gait than the wrist: the bicep swings far less, so
// an on-arm band under-counts walking sharply (owner reports of ~-45% versus
// wrist; mechanism is physics — less motion at the same cadence — but the
// exact ratio is per-user and only measurable against a reference). One global
// gain constant cannot serve both placements, so the calibration profile is
// keyed by wearing location, and the wearing location is something only the
// user knows. `device.wearing` carries it: 1 = wrist (the column default and
// the pre-existing meaning of every row), 2 = bicep/upper arm, 3 = elsewhere
// (chest pocket, ankle-adjacent clothing, a bag). The numbers below are NOT
// calibration factors — they are the KEY SPACE. The factor itself is always
// learned from the user's own phone-covered days; nothing is hard-coded per
// placement beyond which profiles may exist at all.
//
// WHY MULTIPLICATIVE, NOT ADDITIVE
// The documented error mode is proportional (wrist over-counts arm work, arm
// under-counts cadence), and an additive offset would fabricate steps on a
// still day: 0 counter ticks + 200 offset = 200 steps out of nothing. So the
// model is `corrected = rawTicks * factor`, factor clamped to a band wide
// enough to cover the documented error range and narrow enough that a buggy
// reference cannot swing the number arbitrarily.

/// Wearing-location codes stored in `device.wearing`. The integers — not an
/// enum — because the column already exists with DEFAULT 1 on every install,
/// and re-numbering an existing integer space is the one mistake a migration
/// ladder cannot undo. New codes may only be APPENDED.
abstract final class Wearing {
  static const int wrist = 1;
  static const int bicep = 2;
  static const int other = 3;

  /// The closed set this build understands. An unknown code reads back as
  /// null wearing — a refusal, never a silent fall to wrist.
  static const Set<int> known = {wrist, bicep, other};

  /// null for a code this build does not know. A future version may have
  /// written a code it understood and this one does not; borrowing wrist
  /// would calibrate the wrong profile.
  static int? parse(Object? v) {
    final n = v is num ? v.toInt() : null;
    return (n != null && known.contains(n)) ? n : null;
  }
}

/// Hard clamp on the calibration factor. The documented wrist over-count
/// reaches ~+200% and the bicep under-count ~-45%, so a learned factor can
/// legitimately need 2.0 or 0.55 — but a factor outside this band is a
/// reference gone wrong (phone in a drawer all day, counter reset storm), and
/// publishing it would move the user's step number by more than the error it
/// was meant to fix.
const double kStepFactorMin = 0.5;
const double kStepFactorMax = 2.0;

/// Prior weight for the shrinkage toward 1.0. `k` pseudo-days of "factor 1.0"
/// are blended with the observed ratio-days, so a profile built from one
/// afternoon cannot swing the number; `k = 3` means four consistent days are
/// needed before the learned factor dominates the prior.
const double kStepFactorPriorWeight = 3.0;

/// A calibration profile as persisted. Pure data: the estimator and the
/// applier both take this and both are testable without a database.
class StepCalibrationProfile {
  const StepCalibrationProfile({
    required this.deviceFamily,
    required this.wearing,
    required this.factor,
    required this.nDays,
    required this.version,
  });

  /// `Substrate.deviceFamily` — 'gen5' today. A profile is per FAMILY, not
  /// per remote id: two identical bands of the same generation share the
  /// physics, and a device SWAP must not restart learning from the prior.
  final String deviceFamily;

  /// One of [Wearing.known]. The profile is per placement for the reason at
  /// the top of this file.
  final int wearing;

  /// The learned multiplicative factor, already clamped to
  /// [kStepFactorMin, kStepFactorMax]. `1.0` is the honest starting value —
  /// uncalibrated, the raw counter is published as-is.
  final double factor;

  /// How many phone-covered days went into [factor]. Zero means the factor
  /// is pure prior; readers use this to disclose how much was learned.
  final int nDays;

  /// Monotonic version of the LEARNING code, not of the profile row. A bump
  /// means the estimator changed and old learned factors are no longer
  /// comparable; on a bump the re-estimate starts over (nDays resets).
  final int version;

  /// An uncalibrated profile: factor 1.0, nothing learned. What a new family
  /// × placement pair starts from and what a version bump falls back to.
  static StepCalibrationProfile uncalibrated(String deviceFamily, int wearing) =>
      StepCalibrationProfile(
        deviceFamily: deviceFamily,
        wearing: wearing,
        factor: 1.0,
        nDays: 0,
        version: kStepCalibrationVersion,
      );

  /// True when this profile has any learned content. A profile with nDays 0
  /// must read as "not calibrated" in the UI, not as "calibrated to exactly
  /// 1.0" — those are different claims about the data. The fitted factor is
  /// NOT part of this test on purpose: a ratio-of-sums that lands exactly on
  /// 1.0 (phone and counter agreeing across the admitted days) is still a
  /// LEARNED 1.0 with days of evidence behind it — it must emit its
  /// `counter_calibration` disclosure and earn its confidence bump, not be
  /// demoted to the cold-start prior.
  bool get isCalibrated => nDays > 0;
}

/// Version of the estimation code itself. Bump ONLY when the math changes in
/// a way that makes previously learned factors incomparable; the re-estimate
/// then restarts from the prior for every profile.
const int kStepCalibrationVersion = 1;

/// One day's contribution to a profile estimate.
class StepCalibrationDay {
  const StepCalibrationDay({
    required this.referenceSteps,
    required this.counterTicks,
  });

  /// The phone pedometer's total for the day. The REFERENCE — the pocket
  /// counts trunk translation, which is the quantity steps mean.
  final int referenceSteps;

  /// The gen5 on-chip counter's tick total for the same day
  /// (`hardwareStepsFromCounter`'s raw input, before any factor).
  final int counterTicks;
}

/// Whether one day is admitted to the estimator at all. A day the phone did
/// not really cover admits its own noise as reference truth: a phone in a
/// drawer all day reads near-zero and would drag the learned factor toward
/// the floor. Same for a day the counter barely saw — the day's ticks are
/// mostly gap-plausibility droppings.
///
/// The floors are deliberately coarse. They exist to throw out the days that
/// are certainly referenceless, not to fine-tune the estimate; the shrinkage
/// prior handles small-sample noise on the days that pass.
const int kStepCalMinReferenceSteps = 1000;
const int kStepCalMinCounterTicks = 300;

bool stepCalibrationDayAdmissible(StepCalibrationDay d) =>
    d.referenceSteps >= kStepCalMinReferenceSteps &&
    d.counterTicks >= kStepCalMinCounterTicks;

/// Estimate a factor from admitted days, shrunk toward the prior 1.0.
///
/// The raw estimator is a RATIO OF SUMS, not a mean of daily ratios: a mean
/// of ratios lets one quiet day (reference 1,000, counter 200 — a genuine
/// small-value fluke) move the average as much as a heavy walking day, while
/// the ratio of sums weights each day by its evidence, which is the same
/// property that made `resolveDaySteps` subtract overlaps by time rather
/// than by count.
StepCalibrationProfile estimateStepCalibration(
  String deviceFamily,
  int wearing,
  List<StepCalibrationDay> days, {
  int minDays = 3,
}) {
  final admitted =
      days.where(stepCalibrationDayAdmissible).toList(growable: false);
  if (admitted.length < minDays) {
    return StepCalibrationProfile.uncalibrated(deviceFamily, wearing);
  }
  final refSum = admitted.fold<int>(0, (a, d) => a + d.referenceSteps);
  final tickSum = admitted.fold<int>(0, (a, d) => a + d.counterTicks);
  if (tickSum <= 0) {
    return StepCalibrationProfile.uncalibrated(deviceFamily, wearing);
  }
  final ratio = refSum / tickSum;
  final shrunk =
      (admitted.length * ratio + kStepFactorPriorWeight * 1.0) /
          (admitted.length + kStepFactorPriorWeight);
  final clamped = shrunk.clamp(kStepFactorMin, kStepFactorMax);
  return StepCalibrationProfile(
    deviceFamily: deviceFamily,
    wearing: wearing,
    factor: clamped,
    nDays: admitted.length,
    version: kStepCalibrationVersion,
  );
}

/// Apply a profile to a raw counter total. The clamp on the OUTPUT bounds the
/// damage of any upstream integer weirdness; the round is the last step so
/// the published number is an integer count of steps, not a factored float.
int applyStepCalibration(int rawTicks, StepCalibrationProfile? profile) {
  if (rawTicks <= 0 || profile == null || !profile.isCalibrated) return rawTicks;
  final corrected = (rawTicks * profile.factor).round();
  return corrected.clamp(0, (rawTicks * kStepFactorMax).ceil());
}

/// Confidence of a calibrated (or uncalibrated) counter figure, 0..1.
///
/// Uncalibrated keeps the 0.9 the bundle has always published for the
/// counter rung — an honest on-chip count is a good measurement even
/// uncorrected. Calibration only ever EARNS confidence above that, and only
/// with days of evidence; four learned days reach ~0.95, it saturates at
/// 0.98 because a factor learned against a phone is still a factor learned
/// against a proxy, not against ground truth.
double stepCounterConfidence(StepCalibrationProfile? profile) {
  if (profile == null || !profile.isCalibrated) return 0.9;
  return (0.9 + 0.08 * (profile.nDays / (profile.nDays + 4.0)))
      .clamp(0.9, 0.98);
}

/// The wearing location as a stable bundle key — the bundle is JSON, so the
/// integer is the wire format, but a name is what a reader can audit. Kept
/// in the same file as the codes so the mapping cannot drift.
String wearingName(int w) => switch (w) {
      Wearing.wrist => 'wrist',
      Wearing.bicep => 'bicep',
      _ => 'other',
    };
