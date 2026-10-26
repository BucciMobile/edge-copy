// step_detector.dart — the ONE gait step detector: 100 Hz 6-axis IMU → steps.
//
// WHY THIS FILE IS THE WHOLE FEATURE
//
// The Gen5 v18 historical record — the 1 Hz stream `edge` has always stored — is
// NOT a motion signal at a gait-relevant resolution. Its `dynamicAccelerationG`
// is one scalar per second: the max adjacent acceleration-vector-magnitude delta
// the band computed on-chip from its own 100 raw samples. Gait runs at 1.5-3 Hz,
// so a single one-second value is roughly two steps collapsed into one number.
// Peak-detecting that series counts SECONDS, not steps, and no threshold,
// profile or confidence gate can recover what the sample rate already discarded.
//
// The raw path is `Gen5ImuBuffer` (v21): the band's own 100 Hz 6-axis buffer,
// one block ≈ one second of motion. That is the only motion data on a Gen5 strap
// at a sample rate a step detector can work on. This file is the detector for it.
//
// ONE DETECTOR, TWO CALLERS. The calibration run and the everyday estimate MUST
// go through this same class. A calibration that counts steps with different
// maths than the everyday path calibrates a model the app never evaluates —
// the exact drift class `step_cadence.dart` was created to prevent on the
// windows→minutes side.
//
// UNITS AND GRAVITY. Accel axes arrive in g at ±16 g full scale
// (`kGen5AccelScaleG` = 1/4096 per LSB) and INCLUDE gravity — they are not
// gravity-removed. This detector therefore works on the vector MAGNITUDE, which
// is orientation-invariant, and removes the gravity/DC term in the filter rather
// than by subtracting any assumed 1 g: a strap on a moving wrist legitimately
// reads well above 1 g, and a hard-coded subtraction would read that as steps.
//
// COST. O(1) per sample, fixed state, zero allocation on the hot path — the
// stream runs 100 samples/second/axis for hours and must not allocate per sample.
//
// PURE Dart — no I/O, no clock, no protocol import, so it is unit-testable
// against synthetic gait without a band.

import 'dart:math' as math;

/// Tuning for [StepDetector]. Defaults are calibrated for a wrist-worn strap at
/// 100 Hz and are deliberately conservative: a missed step is recovered by the
/// chip counter sharing the day, a FABRICATED step is not recoverable and is the
/// failure the repo's "never fabricate a metric" rule exists to prevent.
class StepDetectorConfig {
  const StepDetectorConfig({
    this.highPassHz = 0.5,
    this.lowPassHz = 5.0,
    this.envelopeTauSec = 1.0,
    this.minAmplitudeG = 0.03,
    this.upperFactor = 0.9,
    this.lowerFactor = 0.5,
    this.minStepIntervalSec = 0.25,
    this.maxStepIntervalSec = 1.0,
    this.minGyroDps = 15.0,
  });

  /// Band-pass lower corner. Removes gravity and slow orientation drift. Set
  /// well below the 1.5 Hz gait floor so the fundamental is not attenuated.
  final double highPassHz;

  /// Band-pass upper corner. Gait harmonics and impact spikes live here; road
  /// and motor vibration sit above it.
  final double lowPassHz;

  /// Time constant of the amplitude reference the threshold is derived from.
  final double envelopeTauSec;

  /// Absolute floor for a dynamic excursion to count at all. Below this the
  /// envelope-derived threshold is used, so a still wrist with sensor noise
  /// cannot produce steps.
  final double minAmplitudeG;

  /// A candidate step is the signal crossing `upperFactor * envelope` upwards.
  final double upperFactor;

  /// Hysteresis: the signal must fall below `lowerFactor * envelope` before the
  /// next crossing is accepted. Without this, one gait cycle's rising AND falling
  /// edge both register and every step is counted twice.
  final double lowerFactor;

  /// Refractory floor — 0.25 s is 4 steps/s, above any sustainable cadence
  /// (elite sprinting peaks near 4.5, which this detector under-counts on
  /// purpose rather than inventing double-steps).
  final double minStepIntervalSec;

  /// Gait-band ceiling on the gap between two consecutive crossings. A crossing
  /// this far from the previous one is not a step: an isolated swell (reaching
  /// for a shelf, a slow arm swing, a shrug) crosses the threshold once and
  /// never again inside a gait interval. 1.0 s = 60 spm, comfortably below any
  /// real walking cadence, and deliberately lenient — the point is to reject
  /// movement that is not repetitive at all, not to police slow walkers.
  final double maxStepIntervalSec;

  /// Rotation floor (deg/s) a candidate step must clear. Walking swings the
  /// wrist hard; a strap riding in a vehicle translates far more than it
  /// rotates, so this is the cheapest usable discriminator between gait and
  /// road vibration. It is a heuristic, not a proof — see the car-vibration
  /// test, which pins the behaviour it is expected to deliver.
  final double minGyroDps;

  double get sampleDtSec => 1.0 / kImuSampleRateHz;
}

/// The gen5 v21 IMU block sample rate. Both blocks are configured at 100 Hz, so
/// one full block is one second of motion — the invariant the block adapter
/// relies on. Partly-filled blocks carry fewer samples at the SAME rate.
const double kImuSampleRateHz = 100.0;

/// One accepted step, as the detector saw it.
class DetectedStep {
  final int sampleIndex;
  final double amplitudeG;

  const DetectedStep({required this.sampleIndex, required this.amplitudeG});
}

/// Running result for one IMU block. Everything a calibration profile needs,
/// with the gravity vector MEASURED from the block rather than assumed.
class ImuBlockResult {
  const ImuBlockResult({
    required this.steps,
    required this.sampleCount,
    required this.durationSec,
    required this.meanAccelX,
    required this.meanAccelY,
    required this.meanAccelZ,
    required this.meanAbsDynamicG,
    required this.peakDynamicG,
    required this.cadenceSpm,
    required this.meanGyroDps,
  });

  /// Steps accepted in this block.
  final int steps;
  final int sampleCount;
  final double durationSec;

  /// Block-mean raw acceleration per axis — the gravity/orientation vector.
  /// Null-free by construction: a block with zero samples still reports its
  /// sample count, and no caller should read these when [sampleCount] is 0.
  final double meanAccelX;
  final double meanAccelY;
  final double meanAccelZ;

  /// Mean of the band-passed magnitude — the movement amplitude of the block.
  final double meanAbsDynamicG;

  /// Largest single dynamic excursion in the block.
  final double peakDynamicG;

  /// Steps per minute from the detector's own step intervals; 0 when fewer than
  /// two steps were accepted, because one interval is not a cadence.
  final double cadenceSpm;

  final double meanGyroDps;

  bool get isEmpty => sampleCount == 0;
}

/// Streaming gait step detector. Feed samples in time order.
///
/// State is fixed-size and updated in place; [process] allocates nothing.
class StepDetector {
  StepDetector({this.config = const StepDetectorConfig()}) {
    _hpA = _onePoleAlpha(config.highPassHz, config.sampleDtSec);
    _lpB = _onePoleBeta(config.lowPassHz, config.sampleDtSec);
    _envB = _emaAlpha(config.envelopeTauSec, config.sampleDtSec);
    _refractorySamples =
        (config.minStepIntervalSec / config.sampleDtSec).round();
    _maxIntervalSamples =
        (config.maxStepIntervalSec / config.sampleDtSec).round();
  }

  final StepDetectorConfig config;

  // ── filter coefficients ───────────────────────────────────────────────────
  late double _hpA;
  late double _lpB;
  late double _envB;
  late int _refractorySamples;
  late int _maxIntervalSamples;

  // ── streaming state (all fixed-size, no per-sample allocation) ─────────────
  double _prevMagnitude = 0.0;
  bool _hasPrev = false;
  double _hp = 0.0;
  double _lp = 0.0;
  double _envelope = 0.0;
  double _gyroEnv = 0.0;

  // Block accumulators. The gravity vector is the arithmetic MEAN of the raw
  // accel over the block — not a long-lag EMA: one block is one second, and a
  // 30 s time constant would still be reading ~0 at the end of it, which is a
  // fabricated gravity vector wearing a measurement's name.
  int _blockSamples = 0;
  double _blockSumX = 0.0;
  double _blockSumY = 0.0;
  double _blockSumZ = 0.0;
  double _blockAbsSum = 0.0;
  double _blockPeak = 0.0;
  double _blockGyroSum = 0.0;

  int _index = 0;
  bool _armed = true;
  int _samplesSinceStep = 1 << 30;

  // Gait-band gate. A crossing is evidence of gait only once a SECOND crossing
  // follows it inside [minStepIntervalSec, maxStepIntervalSec]. Until then it is
  // a pending candidate and counts for nothing — see
  // [StepDetectorConfig.maxStepIntervalSec] for the movement this rejects.
  int _pendingIndex = -1;
  bool _warmed = false;

  int _acceptedSteps = 0;
  double _intervalEma = 0.0;
  int _intervalCount = 0;

  /// Steps accepted since the last [beginBlock].
  int get stepsInBlock => _acceptedSteps;

  /// Steps per minute from this detector's own inter-step intervals. 0 until two
  /// steps have been accepted — a single interval would be a fabricated cadence.
  double get cadenceSpm =>
      _intervalCount == 0 ? 0.0 : 60.0 / (_intervalEma * config.sampleDtSec);

  /// Full reset — a new calibration run or a new block stream starts here.
  void reset() {
    _prevMagnitude = 0.0;
    _hasPrev = false;
    _hp = 0.0;
    _lp = 0.0;
    _envelope = 0.0;
    _gyroEnv = 0.0;
    _blockSamples = 0;
    _blockSumX = 0.0;
    _blockSumY = 0.0;
    _blockSumZ = 0.0;
    _index = 0;
    _armed = true;
    _samplesSinceStep = 1 << 30;
    _pendingIndex = -1;
    _warmed = false;
    _blockAbsSum = 0.0;
    _blockPeak = 0.0;
    _blockGyroSum = 0.0;
    _acceptedSteps = 0;
    _intervalEma = 0.0;
    _intervalCount = 0;
  }

  /// Begin a new IMU block (a v21 buffer). The blocking of features is per
  /// block because the calibration profile is built per block; the FILTER state
  /// deliberately survives, so a step straddling a block boundary is neither
  /// lost nor double-counted.
  void beginBlock() {
    _blockSamples = 0;
    _blockSumX = 0.0;
    _blockSumY = 0.0;
    _blockSumZ = 0.0;
    _blockAbsSum = 0.0;
    _blockPeak = 0.0;
    _blockGyroSum = 0.0;
    _acceptedSteps = 0;
  }

  /// Feed one 100 Hz sample. Returns true when this sample completed a step.
  ///
  /// [axG]/[ayG]/[azG] are g including gravity; [gxDps]/[gyDps]/[gzDps] are deg/s.
  bool process({
    required double axG,
    required double ayG,
    required double azG,
    double gxDps = 0.0,
    double gyDps = 0.0,
    double gzDps = 0.0,
  }) {
    // Block bookkeeping FIRST: every sample counts toward the block's means,
    // including the very first, which the filter cannot process yet. Skipping it
    // would under-count the block and bias the gravity vector.
    _blockSamples++;
    _blockSumX += axG;
    _blockSumY += ayG;
    _blockSumZ += azG;
    final gyroMag = math.sqrt(gxDps * gxDps + gyDps * gyDps + gzDps * gzDps);
    _blockGyroSum += gyroMag;

    // Orientation-invariant magnitude: the strap's rotation cannot move it.
    final magnitude = math.sqrt(axG * axG + ayG * ayG + azG * azG);

    // One-pole high-pass then one-pole low-pass == a 0.5-5 Hz band-pass with two
    // states and no window buffer. It is fed the magnitude DIFFERENCE, so what
    // the high-pass removes is exactly the DC term (gravity) — without ever
    // assuming its size. A strap on a moving wrist legitimately exceeds 1 g.
    if (!_hasPrev) {
      _prevMagnitude = magnitude;
      _hasPrev = true;
      _gyroEnv += _envB * (gyroMag - _gyroEnv);
      return false;
    }
    _hp = _hpA * (_hp + magnitude - _prevMagnitude);
    _prevMagnitude = magnitude;
    _lp += _lpB * (_hp - _lp);

    final dynamic = _lp;
    final absDynamic = dynamic.abs();

    // Amplitude reference. |signal| rather than signal²: the mean of a
    // rectified sinusoid is a stable, phase-independent amplitude proxy, and
    // squaring would weight the impact spike inside a step over the step.
    _envelope += _envB * (absDynamic - _envelope);

    // Gyro corroboration is folded in at the top, band-pass-free on purpose: any
    // rotation at all is the signal we want, and the floor in `minGyroDps` is
    // what absorbs the bias.

    _blockAbsSum += absDynamic;
    if (absDynamic > _blockPeak) _blockPeak = absDynamic;

    _index++;
    if (_samplesSinceStep < 1 << 30) _samplesSinceStep++;

    // Threshold pair from the live amplitude, floored so a still wrist with
    // sensor noise cannot cross.
    final upper = math.max(config.minAmplitudeG, config.upperFactor * _envelope);
    final lower = config.lowerFactor * upper;

    if (!_armed) {
      if (absDynamic < lower) _armed = true;
      return false;
    }

    final rising = dynamic > upper;
    if (!rising) return false;
    if (_samplesSinceStep < _refractorySamples) return false;
    // Gait rotates the wrist. Below the rotation floor this is translation, not
    // walking — the arm-in-a-car case this guard exists for.
    if (_gyroEnv < config.minGyroDps) return false;

    _armed = false;
    _samplesSinceStep = 0;

    // Gait-band gate. A crossing carries no step information on its own: an
    // isolated swell crosses the threshold exactly once. A step is a REPETITION,
    // so the first crossing of a run is held as a candidate and only becomes
    // countable when a second crossing lands inside the gait interval window.
    if (_pendingIndex < 0) {
      _pendingIndex = _index;
      _warmed = false;
      return false;
    }

    final gap = _index - _pendingIndex;
    final inBand = gap >= _refractorySamples && gap <= _maxIntervalSamples;

    if (!_warmed) {
      if (!inBand) {
        // Not repetitive — this crossing replaces the candidate rather than
        // extending it. Nothing counted, which is the honest answer.
        _pendingIndex = _index;
        return false;
      }
      // Two crossings inside the band: the run is real, and BOTH were real
      // steps. The first was held back, not discarded.
      _warmed = true;
      _acceptedSteps += 2;
      _recordInterval(gap.toDouble());
      _pendingIndex = _index;
      return true;
    }

    if (!inBand) {
      // The run broke. This crossing becomes the next candidate; it counts when
      // a crossing follows it in-band.
      _pendingIndex = _index;
      _warmed = false;
      return false;
    }

    _acceptedSteps++;
    _recordInterval(gap.toDouble());
    _pendingIndex = _index;
    return true;
  }

  /// Fold one accepted inter-step gap (in samples) into the cadence estimate.
  void _recordInterval(double gapSamples) {
    _intervalEma = _intervalCount == 0
        ? gapSamples
        : _intervalEma + 0.25 * (gapSamples - _intervalEma);
    _intervalCount++;
  }

  /// Close the current block and report its features. Safe to call on an empty
  /// block: [ImuBlockResult.sampleCount] is then 0 and every mean is 0, which
  /// callers must treat as "no data", not as a measured zero.
  ImuBlockResult endBlock() {
    final count = _blockSamples;
    return ImuBlockResult(
      steps: _acceptedSteps,
      sampleCount: count,
      durationSec: count / kImuSampleRateHz,
      meanAccelX: count == 0 ? 0.0 : _blockSumX / count,
      meanAccelY: count == 0 ? 0.0 : _blockSumY / count,
      meanAccelZ: count == 0 ? 0.0 : _blockSumZ / count,
      meanAbsDynamicG: count == 0 ? 0.0 : _blockAbsSum / count,
      peakDynamicG: _blockPeak,
      cadenceSpm: cadenceSpm,
      meanGyroDps: count == 0 ? 0.0 : _blockGyroSum / count,
    );
  }
}

/// Run a whole 100 Hz block — the six per-axis lists a `Gen5ImuBuffer` carries —
/// through [detector] and return its features.
///
/// The lists are NOT required to be the full 100 samples: a partly-filled block
/// is still a genuine block, and the shortest present axis length bounds the
/// run. Axes shorter than that bound are read as absent rather than zero-padded,
/// because padding would inject a fake still sample into a moving block.
ImuBlockResult detectBlock(
  StepDetector detector, {
  required List<double> accelXg,
  required List<double> accelYg,
  required List<double> accelZg,
  List<double>? gyroXdps,
  List<double>? gyroYdps,
  List<double>? gyroZdps,
}) {
  var n = math.min(accelXg.length, math.min(accelYg.length, accelZg.length));
  final gx = gyroXdps, gy = gyroYdps, gz = gyroZdps;
  if (gx != null && gy != null && gz != null) {
    n = math.min(n, math.min(gx.length, math.min(gy.length, gz.length)));
  }
  detector.beginBlock();
  for (var i = 0; i < n; i++) {
    detector.process(
      axG: accelXg[i],
      ayG: accelYg[i],
      azG: accelZg[i],
      gxDps: gx != null && i < gx.length ? gx[i] : 0.0,
      gyDps: gy != null && i < gy.length ? gy[i] : 0.0,
      gzDps: gz != null && i < gz.length ? gz[i] : 0.0,
    );
  }
  return detector.endBlock();
}

/// `a = RC / (RC + dt)` for a one-pole HIGH-pass at [cutoffHz].
double _onePoleAlpha(double cutoffHz, double dt) {
  final rc = 1.0 / (2 * math.pi * cutoffHz);
  return rc / (rc + dt);
}

/// `b = dt / (RC + dt)` for a one-pole LOW-pass at [cutoffHz].
double _onePoleBeta(double cutoffHz, double dt) {
  final rc = 1.0 / (2 * math.pi * cutoffHz);
  return dt / (rc + dt);
}

/// `b = dt / (tau + dt)` — the plain exponential moving average step.
double _emaAlpha(double tauSec, double dt) => dt / (tauSec + dt);
