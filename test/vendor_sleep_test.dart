import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/oura.dart' show ouraStage4;
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';

int _at(int d, int h, [int m = 0]) =>
    DateTime(2026, 6, d, h, m).millisecondsSinceEpoch ~/ 1000;

/// A night from [on] to [off] cycling light/deep/light/rem every 20 min.
VendorNight _night(int on, int off, {List<String>? cycle, int? decodedAt}) {
  final c = cycle ?? const ['light', 'deep', 'light', 'rem'];
  return VendorNight(
    deviceId: 'ring',
    source: 'oura',
    decodedAtSec: decodedAt ?? off + 600,
    epochs: [
      for (var t = on; t + 30 <= off; t += 30)
        VendorEpoch(t, t + 30, c[((t - on) ~/ 1200) % c.length]),
    ],
  );
}

/// Awake and moving 20:00-23:00, still with a low HR 23:00-07:00, then up.
Substrate _sub() {
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  final asleepFrom = _at(26, 23), asleepTo = _at(27, 7);
  for (var t = _at(26, 20); t < _at(27, 10); t++) {
    final asleep = t >= asleepFrom && t < asleepTo;
    ts.add(t);
    hr.add(asleep ? 50 : 80);
    ax.add(asleep ? 0.02 : math.sin(t / 7));
    ay.add(0.02);
    az.add(asleep ? 1.0 : math.cos(t / 7));
  }
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: const [],
    rrMs: const [],
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List<int>.filled(ts.length, 0),
    spo2Ir: List<int>.filled(ts.length, 0),
    skinTemp: List<int>.filled(ts.length, 0),
    skinContact: List<int>.filled(ts.length, 0),
  );
}

void main() {
  test('ring stage codes map to stages4, an unknown code to nothing', () {
    expect([for (var c = 0; c < 4; c++) ouraStage4(c)],
        ['deep', 'light', 'rem', 'wake']);
    expect(ouraStage4(4), isNull);
    expect(ouraStage4(-1), isNull);
  });

  group('plausibility gate', () {
    final on = _at(26, 23, 10), off = _at(27, 6, 50);
    final oursReal = (onsetSec: _at(26, 23), offsetSec: _at(27, 7));
    String? gate(VendorNight n,
            {({int onsetSec, int offsetSec})? o, bool none = false}) =>
        vendorNightRejection(n,
            dataStartSec: _at(26, 20),
            dataEndSec: _at(27, 10),
            ours: none ? null : (o ?? oursReal));
    VendorNight edit(VendorNight n, List<VendorEpoch> Function(List<VendorEpoch>) f) =>
        VendorNight(
            deviceId: n.deviceId,
            source: n.source,
            decodedAtSec: n.decodedAtSec,
            epochs: f([...n.epochs]));

    test('a plausible night passes', () {
      expect(gate(_night(on, off)), isNull);
    });
    test('a hole between epochs', () {
      expect(gate(edit(_night(on, off), (e) => e..removeRange(100, 110))),
          'gap');
    });
    test('overlapping epochs', () {
      expect(
          gate(edit(_night(on, off),
              (e) => e..insert(100, VendorEpoch(e[90].startSec, e[90].endSec + 300, 'rem')))),
          'overlap');
    });
    test('too short and too long', () {
      expect(gate(_night(on, on + 2 * 3600)), 'length');
      expect(
          vendorNightRejection(_night(_at(26, 12), _at(27, 3)),
              dataStartSec: _at(26, 0),
              dataEndSec: _at(27, 10),
              ours: oursReal),
          'length');
    });
    test('outside the data window, or staged after it was decoded', () {
      expect(gate(_night(_at(26, 19), _at(27, 5))), 'outside_data');
      expect(gate(_night(on, off, decodedAt: off - 3600)), 'outside_data');
    });
    test('one stage all night', () {
      expect(gate(_night(on, off, cycle: const ['light'])), 'degenerate');
    });
    test('no sleep of our own, or one it does not overlap', () {
      expect(gate(_night(on, off), none: true), 'no_own_sleep');
      expect(
          gate(_night(on, off),
              o: (onsetSec: _at(27, 6), offsetSec: _at(27, 9))),
          'no_overlap');
    });
  });

  group('main-sleep precedence', () {
    final vendor = _night(_at(26, 23, 10), _at(27, 6, 50));

    test('without a vendor night the night is ours', () {
      final day = prepareDerivationPayload(_sub(), targetDay: '2026-06-27')
          .days
          .single;
      expect(day.sleepSource, anyOf('auto', 'auto_fallback'));
    });

    test('a vendor night beats auto, and its stages are the ring\'s', () {
      final day = prepareDerivationPayload(_sub(),
              targetDay: '2026-06-27', vendorNights: [vendor])
          .days
          .single;
      expect(day.sleepSource, 'vendor_staged');
      expect(day.sleepOnsetSec, vendor.onsetSec);
      final deep = vendor.epochs.where((e) => e.stage == 'deep').length * 30;
      expect(day.sleepJson['deep_sec'], deep);
      expect(day.hypnoStages.where((s) => s == 'rem'), isNotEmpty);
    });

    test('a vendor night that fails the gate is ignored, with why', () {
      final day = prepareDerivationPayload(_sub(),
          targetDay: '2026-06-27',
          vendorNights: [
            _night(_at(26, 23, 10), _at(27, 6, 50), cycle: const ['deep']),
          ]).days.single;
      expect(day.sleepSource, isNot('vendor_staged'));
      expect(day.flags, contains('VENDOR_SLEEP_IGNORED:oura:degenerate'));
    });

    test('the user override beats a vendor night', () {
      final day = prepareDerivationPayload(_sub(),
          targetDay: '2026-06-27',
          vendorNights: [vendor],
          override: SleepWindowOverride(
            dayId: '2026-06-27',
            onsetSec: _at(26, 23, 30),
            offsetSec: _at(27, 6),
            source: 'manual',
          )).days.single;
      expect(day.sleepSource, 'manual');
    });
  });
}
