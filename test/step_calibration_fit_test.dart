// Tests for the per-category calibration of the live 100 Hz pedometer.
//
// The load-bearing cases are the EVERYDAY ones. A household routine is not zero
// steps — the wearer really does walk to the next room — so the correction must
// come out LOWER without ever reaching zero, and a driving-like window must be
// damped rather than credited at the full wrist rate.
//
// These mirror the Python-mirror harness one-for-one. The mirror is what was
// actually RUN (no Dart/Flutter toolchain was available where this was
// authored); this file is the same cases in the repo's own form, and it has not
// been executed.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/step_calibration_fit.dart';

StepCalibrationRun _gait(
  StepCategory category,
  int expected,
  int raw,
  double cadence,
) =>
    StepCalibrationRun(
      category: category,
      reference: StepReference.wearerCount,
      expectedSteps: expected,
      rawSteps: raw,
      cadenceSpm: cadence,
      peakToPeakG: 1.0,
      confidence: 0.8,
    );

StepCalibrationRun _everyday(int expected, int raw, {double confidence = 0.35}) =>
    StepCalibrationRun(
      category: StepCategory.everyday,
      reference: StepReference.phonePedometer,
      expectedSteps: expected,
      rawSteps: raw,
      cadenceSpm: 95,
      peakToPeakG: 1.4,
      confidence: confidence,
    );

void main() {
  group('admissibility — gait', () {
    test('a walk too short to carry a ratio is refused', () {
      expect(stepRunRejection(_gait(StepCategory.brisk, 30, 32, 110)),
          StepRunRejection.expectedTooSmall);
    });

    test('a detector that saw almost nothing is refused', () {
      expect(stepRunRejection(_gait(StepCategory.brisk, 100, 5, 110)),
          StepRunRejection.rawTooSmall);
    });

    test('a count beyond the clamp is a broken run, not a big gain', () {
      expect(stepRunRejection(_gait(StepCategory.brisk, 100, 250, 110)),
          StepRunRejection.rawExceedsExpectedByTooMuch);
    });

    test('a non-finite feature is refused rather than propagated', () {
      expect(stepRunRejection(_gait(StepCategory.brisk, 100, 110, double.nan)),
          StepRunRejection.nonFiniteFeature);
    });

    test('a gait run referenced to the phone is refused', () {
      final run = StepCalibrationRun(
        category: StepCategory.brisk,
        reference: StepReference.phonePedometer,
        expectedSteps: 100,
        rawSteps: 110,
        cadenceSpm: 110,
        peakToPeakG: 1.0,
        confidence: 0.8,
      );
      expect(stepRunRejection(run), StepRunRejection.referenceWrongSource);
    });

    test('a supervised walk is admitted', () {
      expect(stepRunRejection(_gait(StepCategory.brisk, 100, 110, 110)), isNull);
    });
  });

  group('admissibility — everyday', () {
    test('a reference that counted nothing is refused, not fitted as 0', () {
      // The phone was on a table. That is the ABSENCE of a reference, and a 0.0
      // gain fitted from it would delete every real step in every later
      // household window.
      expect(stepRunRejection(_everyday(0, 400)),
          StepRunRejection.noReferenceSteps);
    });

    test('a reference above the band count is refused', () {
      expect(stepRunRejection(_everyday(500, 400)),
          StepRunRejection.rawExceedsExpectedByTooMuch);
    });

    test('the 50-step floor does not apply to household', () {
      // A household routine is not a gait cadence, so a 30-step reference is a
      // legitimate measurement rather than a run too short to mean anything.
      expect(stepRunRejection(_everyday(30, 400)), isNull);
    });

    test('over-counting household movement is admitted', () {
      expect(stepRunRejection(_everyday(55, 400)), isNull);
    });
  });

  group('the fit', () {
    test('a gait gain takes effect on the first run', () {
      final fit = fittedGain(StepCategory.brisk, [_gait(StepCategory.brisk, 100, 110, 110)]);
      expect(fit!.gain, closeTo(100 / 110, 1e-9));
    });

    test('a household gain comes out low and positive', () {
      final fit = fittedGain(StepCategory.everyday, [_everyday(55, 400)]);
      expect(fit!.gain, closeTo(55 / 400, 1e-9));
      expect(fit.gain, greaterThan(0));
    });

    test('the household gain is floored, never zero', () {
      final fit = fittedGain(StepCategory.everyday, [_everyday(15, 400)]);
      expect(fit!.gain, kEverydayGainMin);
      expect(fit.gain, greaterThan(0));
    });

    test('the household gain can never inflate the count', () {
      final fit = fittedGain(StepCategory.everyday, [_everyday(100, 100)]);
      expect(fit!.gain, lessThanOrEqualTo(kEverydayGainMax));
    });

    test('repeat runs weight by the evidence they carry', () {
      final fit = fittedGain(StepCategory.everyday, [
        _everyday(500, 1400),
        _everyday(55, 400),
      ]);
      expect(fit!.gain, closeTo(555 / 1800, 1e-9));
    });

    test('a run of another family is not evidence for this one', () {
      expect(fittedGain(StepCategory.brisk, [_gait(StepCategory.jog, 100, 110, 170)]),
          isNull);
    });

    test('an uncalibrated family has no fit', () {
      expect(fittedGain(StepCategory.jog, const []), isNull);
    });
  });

  group('cadence bands', () {
    test('the band opens around the median cadence', () {
      final band = categoryBand(StepCategory.brisk, [_gait(StepCategory.brisk, 100, 105, 110)]);
      expect(band!.minSpm, lessThan(110));
      expect(band.maxSpm, greaterThan(110));
    });

    test('the band never leaves the gait window', () {
      final band = categoryBand(StepCategory.slow, [_gait(StepCategory.slow, 100, 100, 75)]);
      expect(band!.minSpm, greaterThanOrEqualTo(kGaitCadenceMinSpm));
      expect(band.maxSpm, lessThanOrEqualTo(kGaitCadenceMaxSpm));
    });

    test('a run that did not walk cannot define a walking band', () {
      expect(categoryBand(StepCategory.slow, [_gait(StepCategory.slow, 100, 100, 55)]),
          isNull);
    });

    test('an outlier run does not drag the band', () {
      final band = categoryBand(StepCategory.brisk, [
        _gait(StepCategory.brisk, 100, 100, 110),
        _gait(StepCategory.brisk, 100, 100, 110),
        _gait(StepCategory.brisk, 100, 100, 190),
      ]);
      expect(band!.maxSpm, lessThan(180));
    });
  });

  group('credit', () {
    final calibrated = [_gait(StepCategory.brisk, 100, 110, 110), _everyday(55, 400)];

    test('a gait window uses the gait gain', () {
      final c = creditLiveSteps(rawSteps: 110, cadenceSpm: 110, runs: calibrated);
      expect(c.category, StepCategory.brisk);
      expect(c.gainApplied, closeTo(100 / 110, 1e-9));
      expect(c.creditedSteps, 100);
      expect(c.calibrated, isTrue);
    });

    test('a household window comes out lower, never zero', () {
      final c = creditLiveSteps(rawSteps: 140, cadenceSpm: 25, runs: calibrated);
      expect(c.category, StepCategory.everyday);
      expect(c.creditedSteps, greaterThan(0));
      expect(c.creditedSteps, lessThan(140));
    });

    test('a driving-like window is damped, not credited at wrist rate', () {
      // 12 spm of road vibration, 25 raw steps. The everyday gain is the
      // backstop BEHIND live_coverage_policy's 40 spm still-hour rule.
      final c = creditLiveSteps(rawSteps: 25, cadenceSpm: 12, runs: calibrated);
      expect(c.creditedSteps, lessThanOrEqualTo(4));
    });

    test('an uncalibrated family is credited exactly as today', () {
      final c = creditLiveSteps(rawSteps: 140, cadenceSpm: 25, runs: const []);
      expect(c.creditedSteps, 140);
      expect(c.gainApplied, 1.0);
      expect(c.calibrated, isFalse);
    });

    test('a gain below 1 can never manufacture steps', () {
      final c = creditLiveSteps(
        rawSteps: 100,
        cadenceSpm: 110,
        runs: [_gait(StepCategory.brisk, 100, 200, 110)],
      );
      expect(c.creditedSteps, lessThanOrEqualTo(100));
    });

    test('a zero or negative raw count stays zero', () {
      expect(creditLiveSteps(rawSteps: 0, cadenceSpm: 110, runs: calibrated).creditedSteps, 0);
      expect(creditLiveSteps(rawSteps: -5, cadenceSpm: 110, runs: calibrated).creditedSteps, 0);
    });
  });

  group('stored profiles', () {
    test('a valid row round-trips', () {
      final p = LiveStepGainProfile(
        version: kLiveStepGainVersion,
        category: StepCategory.brisk,
        gain: 0.977,
        nRuns: 3,
        updatedAt: DateTime.utc(2026, 10, 26),
      );
      final back = LiveStepGainProfile.tryParse(p.toJson());
      expect(back!.gain, closeTo(0.977, 1e-12));
      expect(back.category, StepCategory.brisk);
      expect(back.nRuns, 3);
    });

    test('an everyday gain below the gait floor is legal and round-trips', () {
      final p = LiveStepGainProfile(
        version: kLiveStepGainVersion,
        category: StepCategory.everyday,
        gain: 0.14,
        nRuns: 2,
        updatedAt: DateTime.utc(2026, 10, 26),
      );
      expect(LiveStepGainProfile.tryParse(p.toJson())!.gain, closeTo(0.14, 1e-12));
    });

    test('a gain outside the category band is refused, not loaded', () {
      final json = {
        'v': kLiveStepGainVersion,
        'cat': 'brisk',
        'gain': 0.14, // legal for everyday, not for a gait family
        'n': 1,
        'ts': '2026-10-26T10:00:00Z',
      };
      expect(LiveStepGainProfile.tryParse(json), isNull);
    });

    test('malformed stored data yields null rather than throwing', () {
      expect(LiveStepGainProfile.tryParse('kaputt'), isNull);
      expect(
        LiveStepGainProfile.tryParse({
          'v': kLiveStepGainVersion,
          'cat': 'nope',
          'gain': 1.0,
          'n': 1,
          'ts': '2026-10-26T10:00:00Z',
        }),
        isNull,
      );
      expect(
        LiveStepGainProfile.tryParse({
          'v': 1, // a version this build does not read
          'cat': 'brisk',
          'gain': 1.0,
          'n': 1,
          'ts': '2026-10-26T10:00:00Z',
        }),
        isNull,
      );
      expect(
        LiveStepGainProfile.tryParse({
          'v': kLiveStepGainVersion,
          'cat': 'brisk',
          'gain': 1.0,
          'n': 1,
          'ts': null,
        }),
        isNull,
      );
    });
  });

  group('the calibration session', () {
    test('the LIVE BAND COUNT DOES NOT TERMINATE A GAIT RUN', () {
      // The trap: ending the run when the counter reaches the target would make
      // rawSteps == 100 by construction, so every wearer would fit a gain of
      // exactly 1.0 forever. The wearer counts; the band's live count is only
      // feedback.
      final s = CalibrationSession(category: StepCategory.brisk, targetSteps: 100);
      s.addBandChunk(rawSteps: 56, seconds: 30);
      s.addBandChunk(rawSteps: 56, seconds: 30);
      expect(s.bandRawSteps, 112);
      final out = s.finish();
      expect(out.run!.expectedSteps, 100); // the wearer's count, NOT 112
      expect(out.run!.reference, StepReference.wearerCount);
      final fit = fittedGain(StepCategory.brisk, [out.run!]);
      expect(fit!.gain, closeTo(100 / 112, 1e-9));
      expect(fit.gain, isNot(closeTo(1.0, 0.001)));
    });

    test('the band reports its own cadence for the run', () {
      final s = CalibrationSession(category: StepCategory.brisk);
      s.addBandChunk(rawSteps: 112, seconds: 60);
      final out = s.finish();
      expect(out.run!.cadenceSpm, closeTo(112, 1e-9));
    });

    test('everyday refuses without a phone count instead of fitting a 0.0 gain', () {
      final s = CalibrationSession(category: StepCategory.everyday);
      s.addBandChunk(rawSteps: 400, seconds: 180);
      final out = s.finish();
      expect(out.refusal, StepRunRejection.noReferenceSteps);
      expect(out.run, isNotNull); // the run exists; it is the REFERENCE that does not
    });

    test('everyday with a phone count fits low and positive', () {
      final s = CalibrationSession(category: StepCategory.everyday);
      s.addBandChunk(rawSteps: 400, seconds: 180);
      s.setPhoneSteps(55);
      final out = s.finish();
      expect(out.refusal, isNull);
      expect(fittedGain(StepCategory.everyday, [out.run!])!.gain, closeTo(55 / 400, 1e-9));
    });

    test('everyday progress measures time, gait progress measures the band', () {
      final ed = CalibrationSession(category: StepCategory.everyday, targetSeconds: 180);
      ed.advance(elapsedMs: 90000);
      expect(ed.progress, closeTo(0.5, 1e-9));
      final gait = CalibrationSession(category: StepCategory.brisk, targetSteps: 100);
      gait.addBandChunk(rawSteps: 50, seconds: 30);
      expect(gait.progress, closeTo(0.5, 1e-9));
    });

    test('a silent band is its own outcome, not a refusal', () {
      final s = CalibrationSession(category: StepCategory.jog);
      final out = s.finish();
      expect(out.run, isNull);
      expect(out.refusal, isNull);
      expect(out.bandSilent, isTrue);
    });

    test('nothing is accepted after the run is finished', () {
      final s = CalibrationSession(category: StepCategory.brisk)..finish();
      s.addBandChunk(rawSteps: 50, seconds: 60);
      expect(s.bandRawSteps, 0);
    });

    test('unmeasured features stay absent, never a substituted zero', () {
      final s = CalibrationSession(category: StepCategory.brisk);
      s.addBandChunk(rawSteps: 110, seconds: 60);
      final bare = s.finish().run!;
      expect(bare.peakToPeakG, isNull);
      expect(bare.confidence, isNull);

      final withFeatures = CalibrationSession(category: StepCategory.brisk);
      withFeatures.addBandChunk(rawSteps: 110, seconds: 60);
      withFeatures.setBandFeatures(peakToPeakG: 1.2, confidence: 0.86);
      final full = withFeatures.finish().run!;
      expect(full.peakToPeakG, 1.2);
      expect(full.confidence, 0.86);
    });

    test('a NaN feature is refused rather than stored', () {
      final s = CalibrationSession(category: StepCategory.brisk);
      s.addBandChunk(rawSteps: 110, seconds: 60);
      s.setBandFeatures(confidence: double.nan);
      expect(s.finish().refusal, StepRunRejection.nonFiniteFeature);
    });
  });
}
