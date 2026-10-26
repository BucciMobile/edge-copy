// Tests for the 100 Hz IMU gait step detector.
//
// These are the cases that decide whether the detector is shippable, and each
// one exists because a naive peak counter fails it:
//
//  * rest            — no step may ever be fabricated from sensor noise
//  * walk / jog      — the count must land inside ±10 % of the truth
//  * vehicle         — 12 Hz road vibration is not gait
//  * slow sway       — one crossing is not a repetition
//  * no rotation     — translation without wrist rotation is not walking
//  * block framing   — splitting the stream must not change the total
//  * degenerate      — empty / partly-filled / gyro-less blocks must not throw
//  * gravity         — the block's gravity vector is measured, never assumed
//
// The synthetic signals put the inertial component on the VERTICAL axis, which
// is the physics that matters: during real gait the swing adds to gravity, so
// the magnitude oscillates at the STEP frequency. Adding the swing on a
// horizontal axis would make the magnitude oscillate at 2f and would test a
// signal no real walk produces.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/step_detector.dart';

int _seed = 7;
double _noise() {
  _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
  return (_seed / 0x7fffffff) * 2 - 1;
}

class _Sig {
  final List<double> ax, ay, az, gx, gy, gz;
  const _Sig(this.ax, this.ay, this.az, this.gx, this.gy, this.gz);
  int get n => ax.length;
}

_Sig _gait({
  required double hz,
  required double ampG,
  required double gyroDps,
  required int samples,
  double noise = 0.015,
}) {
  final ax = <double>[], ay = <double>[], az = <double>[];
  final gx = <double>[], gy = <double>[], gz = <double>[];
  final w = 2 * math.pi * hz;
  for (var i = 0; i < samples; i++) {
    final p = w * i / kImuSampleRateHz;
    az.add(1.0 + ampG * math.sin(p) + noise * _noise());
    ax.add(0.15 * ampG * math.sin(p + 0.4) + noise * _noise());
    ay.add(0.10 * ampG * math.cos(p + 0.9) + noise * _noise());
    gx.add(gyroDps * math.sin(p) + 2 * _noise());
    gy.add(0.5 * gyroDps * math.cos(p) + 2 * _noise());
    gz.add(0.2 * gyroDps * math.sin(p + 1.1) + 2 * _noise());
  }
  return _Sig(ax, ay, az, gx, gy, gz);
}

int _count(_Sig s, [StepDetector? d]) {
  final det = d ?? StepDetector();
  var n = 0;
  for (var i = 0; i < s.n; i++) {
    if (det.process(
      axG: s.ax[i],
      ayG: s.ay[i],
      azG: s.az[i],
      gxDps: s.gx[i],
      gyDps: s.gy[i],
      gzDps: s.gz[i],
    )) {
      n++;
    }
  }
  return n;
}

bool _near(num v, num want, double pct) =>
    (v - want).abs() <= (want.abs() * pct).abs() + 1.5;

void main() {
  setUp(() => _seed = 7);

  test('rest never produces a step', () {
    final s = _gait(hz: 0.0001, ampG: 0, gyroDps: 0, samples: 6000, noise: 0.008);
    expect(_count(s), 0);
  });

  test('walking 1.8 Hz for 60 s lands within 10 % of the truth', () {
    final s = _gait(hz: 1.8, ampG: 0.25, gyroDps: 120, samples: 6000);
    expect(_near(_count(s), 108, 0.10), isTrue);
  });

  test('jogging 2.8 Hz for 30 s lands within 10 % of the truth', () {
    final s = _gait(hz: 2.8, ampG: 0.8, gyroDps: 300, samples: 3000);
    expect(_near(_count(s), 84, 0.10), isTrue);
  });

  test('vehicle vibration at 12 Hz is not gait', () {
    final s = _gait(hz: 12, ampG: 0.15, gyroDps: 5, samples: 6000);
    expect(_count(s), 0);
  });

  test('a 0.3 Hz sway is one crossing per cycle, not a repetition', () {
    final s = _gait(hz: 0.3, ampG: 0.2, gyroDps: 40, samples: 6000);
    expect(_count(s), 0);
  });

  test('translation without wrist rotation is rejected by the gyro gate', () {
    final s = _gait(hz: 1.8, ampG: 0.25, gyroDps: 0, samples: 3000);
    expect(_count(s), 0);
  });

  test('block framing does not change the total', () {
    final s = _gait(hz: 1.8, ampG: 0.25, gyroDps: 120, samples: 6000);
    final continuous = _count(s);
    final det = StepDetector();
    var blocked = 0;
    for (var b = 0; b < 60; b++) {
      det.beginBlock();
      for (var i = b * 100; i < (b + 1) * 100; i++) {
        det.process(
          axG: s.ax[i],
          ayG: s.ay[i],
          azG: s.az[i],
          gxDps: s.gx[i],
          gyDps: s.gy[i],
          gzDps: s.gz[i],
        );
      }
      blocked += det.endBlock().steps;
    }
    expect((blocked - continuous).abs(), lessThanOrEqualTo(2));
  });

  test('an empty block reports zero samples rather than crashing', () {
    final det = StepDetector()..beginBlock();
    final r = det.endBlock();
    expect(r.sampleCount, 0);
    expect(r.steps, 0);
    expect(r.isEmpty, isTrue);
  });

  test('a partly-filled block is processed, not rejected', () {
    final s = _gait(hz: 1.8, ampG: 0.25, gyroDps: 120, samples: 6000);
    final r = detectBlock(
      StepDetector(),
      accelXg: s.ax.sublist(0, 40),
      accelYg: s.ay.sublist(0, 40),
      accelZg: s.az.sublist(0, 40),
      gyroXdps: s.gx.sublist(0, 40),
      gyroYdps: s.gy.sublist(0, 40),
      gyroZdps: s.gz.sublist(0, 40),
    );
    expect(r.sampleCount, 40);
  });

  test('a block with no gyro data is processed without throwing', () {
    final s = _gait(hz: 1.8, ampG: 0.25, gyroDps: 120, samples: 6000);
    final r = detectBlock(
      StepDetector(),
      accelXg: s.ax.sublist(0, 100),
      accelYg: s.ay.sublist(0, 100),
      accelZg: s.az.sublist(0, 100),
    );
    expect(r.sampleCount, 100);
  });

  test('the gravity vector is measured from the block', () {
    final s = _gait(hz: 1.8, ampG: 0.25, gyroDps: 120, samples: 6000);
    final r = detectBlock(
      StepDetector(),
      accelXg: s.ax.sublist(0, 100),
      accelYg: s.ay.sublist(0, 100),
      accelZg: s.az.sublist(0, 100),
      gyroXdps: s.gx.sublist(0, 100),
      gyroYdps: s.gy.sublist(0, 100),
      gyroZdps: s.gz.sublist(0, 100),
    );
    expect((r.meanAccelZ - 1.0).abs(), lessThan(0.15));
  });

  test('cadence lands in the walking band', () {
    final s = _gait(hz: 1.8, ampG: 0.25, gyroDps: 120, samples: 6000);
    final det = StepDetector();
    _count(s, det);
    expect(det.cadenceSpm, greaterThan(90));
    expect(det.cadenceSpm, lessThan(140));
  });

  test('calibration and everyday use one detector, so the ordering holds', () {
    final slow = _count(_gait(hz: 1.5, ampG: 0.15, gyroDps: 70, samples: 6000));
    final brisk = _count(_gait(hz: 1.9, ampG: 0.35, gyroDps: 150, samples: 6000));
    final jog = _count(_gait(hz: 2.8, ampG: 0.8, gyroDps: 300, samples: 6000));
    expect(slow, lessThan(brisk));
    expect(brisk, lessThan(jog));
  });

  test('reset clears the run so a new calibration starts clean', () {
    final s = _gait(hz: 1.8, ampG: 0.25, gyroDps: 120, samples: 3000);
    final det = StepDetector();
    final first = _count(s, det);
    det.reset();
    final second = _count(s, det);
    expect(second, first);
  });
}
