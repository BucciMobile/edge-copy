// Unit tests for the pure context model (lib/compute/context_model.dart):
// expected-deviation offsets, residual computation, mask windows, calibration
// stages and the wear-gap rule. No DB, no Flutter bindings — the module is
// isolate-safe pure, so these run anywhere.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/context_model.dart';

/// n consecutive day labels starting 2024-01-01 (a Monday).
List<String> _dates(int n, {int startDay = 1}) {
  final out = <String>[];
  for (var i = 0; i < n; i++) {
    final dt = DateTime(2024, 1, startDay + i);
    out.add(
      '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}',
    );
  }
  return out;
}

/// A clean baseline series: rhr 55 ± wobble, rmssd 45 ms, resp 14, temp 3000.
({List<double?> rhr, List<double?> rmssd, List<double?> resp, List<double?> temp})
    _clean(int n, {double rhrBase = 55, double rmssdBase = 45}) {
  return (
    rhr: <double?>[for (var i = 0; i < n; i++) rhrBase + (i % 5) - 2],
    rmssd: <double?>[for (var i = 0; i < n; i++) rmssdBase + ((i % 5) - 2) * 1.5],
    resp: <double?>[for (var i = 0; i < n; i++) 14 + ((i % 5) - 2) * 0.3],
    temp: <double?>[for (var i = 0; i < n; i++) 3000 + ((i % 5) - 2) * 8],
  );
}

ContextResiduals _build(
  int n, {
  List<double?>? rhr,
  List<double?>? rmssd,
  List<double?>? resp,
  List<double?>? temp,
  List<double?>? strain,
  List<double?>? tstMin,
  Map<String, List<String>> journalTagsByDate = const {},
  Map<String, Map<String, List<num?>>> journalMetricsByDate = const {},
  List<String> cycleStartDates = const [],
  List<bool>? unsettled,
  List<String>? dates,
}) {
  final d = dates ?? _dates(n);
  final c = _clean(n);
  return buildContextResiduals(
    dates: d,
    unsettled: unsettled ?? List<bool>.filled(n, false),
    rhr: rhr ?? c.rhr,
    rmssd: rmssd ?? c.rmssd,
    resp: resp ?? c.resp,
    tempAlert: temp ?? c.temp,
    strain: strain ?? List<double?>.filled(n, null),
    tstMin: tstMin ?? List<double?>.filled(n, 450),
    journalTagsByDate: journalTagsByDate,
    journalMetricsByDate: journalMetricsByDate,
    cycleStartDates: cycleStartDates,
  );
}

void main() {
  group('no-context compatibility', () {
    test('with no journal/cycle/strain/debt context the residual IS the raw value',
        () {
      // Byte-for-byte compatibility for context-free nights: the detectors
      // must see exactly what they saw before the context model existed.
      final n = 12;
      final c = _clean(n);
      final r = _build(n, tstMin: List<double?>.filled(n, null));
      expect(r.rhrResidual, c.rhr);
      expect(r.hrvResidual, c.rmssd);
      expect(r.respResidual, c.resp);
      expect(r.tempResidual, c.temp);
      expect(r.masks.every((m) => m.isEmpty), isTrue);
    });

    test('an unsettled night has null residuals, never a fabricated one', () {
      final n = 12;
      final unsettled = List<bool>.filled(n, false)..[10] = true;
      final r = _build(n, unsettled: unsettled, tstMin: List<double?>.filled(n, null));
      expect(r.rhrResidual[10], isNull);
      expect(r.hrvResidual[10], isNull);
      expect(r.tempResidual[10], isNull);
      // Its neighbours are untouched.
      expect(r.rhrResidual[9], isNotNull);
    });
  });

  group('training-load masking', () {
    test('a hard day (strain 18) suppresses the expected next-night RHR/HRV rise',
        () {
      final n = 40;
      final c = _clean(n);
      final strain = List<double?>.filled(n, 6.0)..[37] = 18.0;
      final rhr = [...c.rhr]..[38] = 59.0; // +4 bpm next night
      final rmssd = [...c.rmssd]..[38] = 33.75; // −25 %
      final r = _build(n, rhr: rhr, rmssd: rmssd, strain: strain);
      expect(r.masks[38], contains('load'));
      // Residual RHR: 59 minus the load expectation (~0.15*18 + 0.05*mean7)
      // must be far below the raw +4 bpm.
      final raw = rhr[38]! - 55.0;
      final resid = r.rhrResidual[38]! - 55.0;
      expect(resid, lessThan(raw * 0.3));
      // HRV residual is much smaller in magnitude than the raw −25 %.
      final rawHrv = rmssd[38]! - 45.0;
      expect((r.hrvResidual[38]! - 45.0).abs(), lessThan(rawHrv.abs() * 0.3));
    });
  });

  group('journal masks', () {
    test('alcohol dose scales the RHR mask and is capped', () {
      final n = 40;
      final dates = _dates(n);
      final c = _clean(n);
      final rhr = [...c.rhr]..[38] = 63.0;
      // 2 units on the day before night 38 -> 2*1.5 = 3 bpm expected.
      final r2 = _build(n, rhr: rhr, journalMetricsByDate: {
        dates[37]: {
          'alcohol_units': [2, 1320],
        },
      });
      expect(r2.masks[38], contains('alcohol'));
      expect(r2.rhrResidual[38], closeTo(63.0 - 3.0, 0.001));
      // 20 units -> capped at kAlcoholRhrBpmCap.
      final r20 = _build(n, rhr: rhr, journalMetricsByDate: {
        dates[37]: {
          'alcohol_units': [20, 1320],
        },
      });
      expect(r20.rhrResidual[38], closeTo(63.0 - kAlcoholRhrBpmCap, 0.001));
    });

    test("'alcohol' tag alone masks one unit's worth", () {
      final n = 40;
      final dates = _dates(n);
      final c = _clean(n);
      final rhr = [...c.rhr]..[38] = 63.0;
      final r = _build(n, rhr: rhr, journalTagsByDate: {
        dates[37]: ['alcohol'],
      });
      expect(r.masks[38], contains('alcohol'));
      expect(r.rhrResidual[38], closeTo(63.0 - kAlcoholRhrBpmPerUnit, 0.001));
    });

    test("'vaccinated' masks the next 3 nights (48–72 h), not the 4th", () {
      final n = 45;
      final dates = _dates(n);
      final r = _build(n, journalTagsByDate: {
        dates[36]: ['vaccinated'],
      });
      expect(r.masks[37], contains('vaccination'));
      expect(r.masks[38], contains('vaccination'));
      expect(r.masks[39], contains('vaccination'));
      expect(r.masks[40], isNot(contains('vaccination')));
    });

    test("'travel' reduces sensitivity for the next 2 nights only", () {
      final n = 40;
      final dates = _dates(n);
      final c = _clean(n);
      final rhr = [...c.rhr]..[38] = 59.0;
      final r = _build(n, rhr: rhr, journalTagsByDate: {
        dates[37]: ['travel'],
      });
      expect(r.masks[38], contains('travel'));
      expect(r.masks[39], contains('travel'));
      expect(r.masks[40], isNot(contains('travel')));
      // The RHR residual is reduced by kTravelRhrZ robust-z units.
      final noMask = _build(n, rhr: rhr, tstMin: List<double?>.filled(n, null));
      final masked = r.rhrResidual[38]!;
      final unmasked = noMask.rhrResidual[38]!;
      expect(unmasked - masked, greaterThan(1.0)); // ~1.5 z ≈ 2.2 bpm at MAD 1.48
    });

    test("'sick' is a near-full self-reported mask on the night it describes", () {
      final n = 40;
      final dates = _dates(n);
      final c = _clean(n);
      final rhr = [...c.rhr]..[38] = 64.0; // +9 bpm
      final r = _build(n, rhr: rhr, journalTagsByDate: {
        dates[38]: ['sick'], // retrospective: describes this night
      });
      expect(r.masks[38], contains('sick'));
      // kSickRhrZ=3 z-units at robust scale ~1.4826 bpm ≈ 4.4 bpm off the +9.
      expect(r.rhrResidual[38]! - 55.0, lessThan(5.0));
    });

    test('late caffeine (≥200 mg after 16:00) masks the following night', () {
      final n = 40;
      final dates = _dates(n);
      final r = _build(n, journalMetricsByDate: {
        dates[37]: {
          'caffeine_mg': [250, 17 * 60 + 30],
        },
      });
      expect(r.masks[38], contains('late caffeine'));
      // Early caffeine does not.
      final r2 = _build(n, journalMetricsByDate: {
        dates[37]: {
          'caffeine_mg': [250, 9 * 60],
        },
      });
      expect(r2.masks[38], isNot(contains('late caffeine')));
    });
  });

  group('sleep debt', () {
    test('one short night is expected context, not a warning input', () {
      final n = 40;
      final c = _clean(n);
      final tst = List<double?>.filled(n, 450.0)..[38] = 300.0; // 150 min short
      final rhr = [...c.rhr]..[38] = 58.0; // +3 bpm
      final rmssd = [...c.rmssd]..[38] = 38.0; // −15 %
      final r = _build(n, rhr: rhr, rmssd: rmssd, tstMin: tst);
      expect(r.masks[38], contains('sleep_debt'));
      // Expected RHR offset = 0.02 * 150 = 3 bpm — exactly the observed rise.
      expect(r.rhrResidual[38], closeTo(55.0, 0.001));
    });

    test('no sleep-need estimate (under 7 nights) means no debt mask, raw passes through',
        () {
      final n = 6;
      final c = _clean(n);
      final tst = List<double?>.filled(n, 450.0)..[5] = 300.0;
      final rhr = [...c.rhr]..[5] = 58.0;
      final r = _build(n, rhr: rhr, tstMin: tst);
      expect(r.masks[5], isNot(contains('sleep_debt')));
      expect(r.rhrResidual[5], rhr[5]);
    });
  });

  group('cycle stratification', () {
    test('lutealFlags: second half of each logged cycle, all-false with <2 starts',
        () {
      final dates = _dates(40);
      // One start only -> no cycle length -> nothing counts.
      expect(lutealFlags(dates, const ['2024-01-01']).every((b) => !b), isTrue);
      // Two starts 28 days apart: closed cycle 01-01..01-29 (len 28), open
      // cycle from 01-29 with median gap 28 -> luteal from elapsed >= 14.
      final l = lutealFlags(dates, const ['2023-12-04', '2024-01-01']);
      expect(l[0], isFalse); // 2024-01-01, elapsed 0
      expect(l[13], isFalse); // 2024-01-14, elapsed 13 < 14
      expect(l[14], isTrue); // 2024-01-15, elapsed 14 >= 14
      expect(l[39], isTrue); // still inside 1.5 cycles of the open start
    });

    test('a luteal-phase temp rise is subtracted as expected deviation', () {
      final n = 40;
      final c = _clean(n);
      // +20 ADC on every luteal night (from 2024-01-15 on, with the cycle log).
      final temp = <double?>[
        for (var i = 0; i < n; i++) (c.temp[i] ?? 0) + (i >= 14 ? 20 : 0),
      ];
      final cycle = const ['2023-12-04', '2024-01-01'];
      final r = _build(n, temp: temp, cycleStartDates: cycle);
      // A luteal night's temp residual is back near the raw wobble band.
      expect(r.masks[30], contains('luteal'));
      final residZ = (r.tempResidual[30]! - 3000) / 8;
      expect(residZ.abs(), lessThan(2.5)); // raw would be ~+2.5 z plus wobble
      // Without cycle data the same rise passes through unmasked.
      final r0 = _build(n, temp: temp, tstMin: List<double?>.filled(n, null));
      expect(r0.tempResidual[30], temp[30]);
    });

    test('too few luteal nights -> no empirical offset, raw passes through', () {
      final n = 20;
      final c = _clean(n);
      final temp = <double?>[
        for (var i = 0; i < n; i++) (c.temp[i] ?? 0) + (i >= 14 ? 20 : 0),
      ];
      // Only ~6 luteal nights but the window before night 19 holds 5 — border;
      // use a cycle that makes only 2 nights luteal to be safely under the floor.
      final cycle = const ['2023-12-20', '2024-01-17'];
      final r = _build(n, temp: temp, cycleStartDates: cycle);
      expect(r.masks[19], isNot(contains('luteal')));
      expect(r.tempResidual[19], temp[19]);
    });
  });

  group('calibration stages', () {
    ContextResiduals calFor(int validNights, {List<String>? dates}) {
      final n = validNights;
      return _build(n, dates: dates);
    }

    test('stage boundaries: 6->0, 7->1, 13->1, 14->2, 29->2, 30->3', () {
      expect(calFor(6).calibration['stage'], 0);
      expect(calFor(7).calibration['stage'], 1);
      expect(calFor(13).calibration['stage'], 1);
      expect(calFor(14).calibration['stage'], 2);
      expect(calFor(29).calibration['stage'], 2);
      expect(calFor(30).calibration['stage'], 3);
      expect(calFor(30).calibration['stage_label'], 'full');
      expect(calFor(5).calibration['stage_label'], 'calibrating');
      expect(calFor(30).calibration['valid_nights'], 30);
    });

    test('unsettled nights do not count as valid', () {
      final n = 30;
      final unsettled = List<bool>.filled(n, false);
      for (var i = 20; i < n; i++) {
        unsettled[i] = true;
      }
      final r = _build(n, unsettled: unsettled);
      expect(r.calibration['valid_nights'], 20);
      expect(r.calibration['stage'], 2);
    });

    test('a wear gap >14 days drops exactly one stage, keeping the prior', () {
      // 35 valid nights (2024-01-01..2024-02-04), then a 21-calendar-day gap,
      // then 3 more (2024-02-25..2024-02-27). DateTime normalizes the day
      // overflow, so startDay 56 == 2024-02-25.
      final dates = <String>[
        for (var i = 0; i < 35; i++) _dates(1, startDay: 1 + i).first,
        for (var i = 0; i < 3; i++) _dates(1, startDay: 56 + i).first,
      ];
      expect(dates[34], '2024-02-04');
      expect(dates[35], '2024-02-25');
      final r = _build(dates.length, dates: dates);
      expect(r.calibration['valid_nights'], 38);
      expect(r.calibration['max_gap_days'], 21);
      expect(r.calibration['gap_drop'], isTrue);
      // 38 valid nights would be stage 3; the gap drops it to 2.
      expect(r.calibration['stage'], 2);
    });

    test('a gap of exactly 14 days does not drop the stage', () {
      // 32 nights (2024-01-01..2024-02-01), gap of exactly 14 days, then
      // 2024-02-15..2024-02-17 (startDay 46..48).
      final dates = <String>[
        for (var i = 0; i < 32; i++) _dates(1, startDay: 1 + i).first,
        for (var i = 0; i < 3; i++) _dates(1, startDay: 46 + i).first,
      ];
      expect(dates[31], '2024-02-01');
      expect(dates[32], '2024-02-15');
      final r = _build(dates.length, dates: dates);
      expect(r.calibration['max_gap_days'], 14);
      expect(r.calibration['gap_drop'], isFalse);
      expect(r.calibration['stage'], 3); // 35 valid nights, no drop
    });

    test('per-signal availability is counted honestly (missing temp shows as 0)',
        () {
      final n = 30;
      final r = _build(n, temp: List<double?>.filled(n, null));
      final signals = r.calibration['signals'] as Map;
      expect(signals['temp'], 0);
      expect(signals['rhr'], 30);
      expect(r.calibration['cycle_aware'], isFalse);
    });
  });
}
