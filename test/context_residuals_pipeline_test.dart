// Section-7 false-positive / degradation fixtures, driven through the REAL
// cross-day pipeline (buildCrossDayBundle) with journal context supplied — the
// same seam DerivationEngine._runCrossDay uses (_journalByDate → journalByDate).
//
// The overnight detectors (illness CUSUM, multivariate anomaly, skin-temp
// flag) now run on RESIDUALS (actual − expected-from-context). These tests pin
// that a night with an explanation (hard workout, alcohol, vaccination, luteal
// phase, travel, one short sleep) does NOT fire, that an unexplained
// multi-night constellation DOES, that missing signals degrade honestly, and
// that the calibration stages unlock at 7/14/30 valid nights with the
// wear-gap rule.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';

/// n synthetic days from 2024-01-01, clean baseline: rhr 55±2, rmssd 45 ms,
/// resp 14, temp 3000 ADC (gen4), strain ~6-8, tst 450 min.
List<Map<String, dynamic>> _days(int n) {
  final days = <Map<String, dynamic>>[];
  for (var i = 0; i < n; i++) {
    final dt = DateTime(2024, 1, 1 + i);
    final date =
        '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    final wobble = (i % 5) - 2; // -2..2
    days.add({
      'date': date,
      'rhr': 55.0 + wobble,
      'rmssd': 45.0 + wobble * 1.5,
      'readiness': 70.0 + wobble * 2,
      'resp_rate': 14.0 + wobble * 0.3,
      'skin_temp_z': wobble * 0.4,
      'skin_temp_adc': 3000.0 + wobble * 8.0,
      'skin_temp_family': 'gen4',
      'trimp': 80.0,
      'strain': 6.0 + (i % 3),
      'tst_min': 450,
      'onset_sec': 23 * 3600,
      'wake_sec': 31 * 3600,
    });
  }
  return days;
}

List<Map<String, dynamic>> _withGap() {
  // 35 nights 2024-01-01..2024-02-04, 21-day wear gap, 3 nights 2024-02-25..27.
  return [
    ..._days(35),
    ..._days(3).asMap().entries.map((e) {
      final d = Map<String, dynamic>.from(e.value);
      final dt = DateTime(2024, 2, 25 + e.key);
      d['date'] =
          '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      return d;
    }),
  ];
}

Map<String, dynamic> _journal(String date, {List<String> tags = const [], Map<String, List<num?>> metrics = const {}}) => {
      'tags': tags,
      if (metrics.isNotEmpty) 'metrics': metrics,
    };

List<dynamic> _recent(Map<String, dynamic> bundle) =>
    bundle['recent'] as List<dynamic>;

void main() {
  group('byte-for-byte compatibility without context', () {
    test('no journal + no strain/sleep inputs: residuals equal the raw values',
        () {
      final days = _days(40).map((d) {
        final c = Map<String, dynamic>.from(d);
        c['strain'] = null;
        c['tst_min'] = null;
        return c;
      }).toList();
      final b = buildCrossDayBundle(days, const {});
      final recent = _recent(b);
      for (var i = 0; i < days.length; i++) {
        final r = recent[i] as Map;
        expect(r['rhr_residual'], days[i]['rhr']);
        expect(r['hrv_residual'], days[i]['rmssd']);
        expect(r['resp_residual'], days[i]['resp_rate']);
        expect(r['temp_residual'], days[i]['skin_temp_adc']);
        expect(r['masks'], isEmpty);
      }
      expect(b['calibration']['stage'], 3); // 40 valid nights
      expect(b['context_model']['version'], 1);
    });
  });

  group('MUST NOT fire (context-masked)', () {
    test('fixture 1: hard workout day -> suppressed HRV / slightly up RHR does not fire',
        () {
      final days = _days(41);
      days[37]['strain'] = 18.0; // very hard day 2024-02-07
      days[38]['rhr'] = 59.0; // +4 bpm next night
      days[38]['rmssd'] = 33.75; // −25 %
      final b = buildCrossDayBundle(days, const {});
      final recent = _recent(b);
      final r38 = recent[38] as Map;
      expect(r38['masks'], contains('load'));
      expect(recent.sublist(36).any((r) => (r as Map)['illness'] == true),
          isFalse);
      expect(recent.sublist(36).any((r) => (r as Map)['anomaly'] == true),
          isFalse);
    });

    test('fixture 2: alcohol journaled in the evening -> no illness anomaly', () {
      final days = _days(41);
      days[38]['rhr'] = 63.0; // +8 bpm rebound
      days[38]['rmssd'] = 29.0; // −35 %
      final date37 =
          (days[37] as Map)['date'] as String; // 2024-02-07, the day before
      final b = buildCrossDayBundle(days, const {}, journalByDate: {
        date37: _journal(date37, metrics: {
          'alcohol_units': [2, 1320], // 2 units, last at 22:00
        }),
      });
      final recent = _recent(b);
      expect((recent[38] as Map)['masks'], contains('alcohol'));
      expect(recent.sublist(36).any((r) => (r as Map)['illness'] == true),
          isFalse,
          reason: 'the alcohol rebound is expected, not an anomaly');
      expect(recent.sublist(36).any((r) => (r as Map)['anomaly'] == true),
          isFalse);
      // Control: the SAME night without the journal entry DOES fire.
      final b0 = buildCrossDayBundle(days, const {});
      expect(
          _recent(b0).sublist(36).any((r) => (r as Map)['illness'] == true),
          isTrue);
    });

    test('fixture 3: vaccination journaled -> temp/HRV spike suppressed for 72 h',
        () {
      final days = _days(45);
      for (var i = 37; i <= 39; i++) {
        days[i]['rhr'] = 59.0; // +4 bpm
        days[i]['skin_temp_adc'] = 3030.0; // ~+2.5 z
        days[i]['rmssd'] = 38.0;
      }
      final date36 = (days[36] as Map)['date'] as String; // 2024-02-06
      final b = buildCrossDayBundle(days, const {}, journalByDate: {
        date36: _journal(date36, tags: const ['vaccinated']),
      });
      final recent = _recent(b);
      for (var i = 37; i <= 39; i++) {
        expect((recent[i] as Map)['masks'], contains('vaccination'));
      }
      expect((recent[40] as Map)['masks'], isNot(contains('vaccination')));
      expect(recent.sublist(36).any((r) => (r as Map)['illness'] == true),
          isFalse);
      expect(recent.sublist(36).any((r) => (r as Map)['temp'] == true),
          isFalse);
      // Control: same spikes without the tag fire the temperature flag.
      final b0 = buildCrossDayBundle(days, const {});
      expect(_recent(b0).sublist(36).any((r) => (r as Map)['temp'] == true),
          isTrue);
    });

    test('fixture 4: luteal-phase skin-temp rise with cycle data -> no temp flag',
        () {
      final days = _days(41);
      for (var i = 14; i < days.length; i++) {
        // +32 ADC on every second-half-of-cycle night (~+2.7 z on the
        // detector's scaled-MAD scale, above its 2.0 flag threshold).
        days[i]['skin_temp_adc'] = (days[i]['skin_temp_adc'] as num) + 32.0;
      }
      const cycle = ['2023-12-04', '2024-01-01']; // 28-day cycles
      final b = buildCrossDayBundle(days, const {}, cycleStartDates: cycle);
      final recent = _recent(b);
      expect(recent.any((r) => (r as Map)['temp'] == true), isFalse);
      expect((recent[30] as Map)['masks'], contains('luteal'));
      // Control: no cycle data -> the same rise is flagged.
      final b0 = buildCrossDayBundle(days, const {});
      expect(_recent(b0).any((r) => (r as Map)['temp'] == true), isTrue);
    });

    test('fixture 5: travel flag -> sensitivity reduced for 2 nights, no fire', () {
      final days = _days(41);
      days[38]['rhr'] = 58.5; // +3.5 bpm
      final date37 = (days[37] as Map)['date'] as String;
      final b = buildCrossDayBundle(days, const {}, journalByDate: {
        date37: _journal(date37, tags: const ['travel']),
      });
      final recent = _recent(b);
      expect((recent[38] as Map)['masks'], contains('travel'));
      expect((recent[39] as Map)['masks'], contains('travel'));
      expect((recent[40] as Map)['masks'], isNot(contains('travel')));
      expect(recent.sublist(36).any((r) => (r as Map)['illness'] == true),
          isFalse);
    });

    test('fixture 6: one single bad night after a clean month -> no multivariate flag',
        () {
      // The anomaly detector requires 2 consecutive candidates (persistence);
      // a single bad night is noise (Plews 2013) and must not flag it.
      final days = _days(41);
      days[38]['rhr'] = 75.0; // one +20 bpm night, then back to normal
      final b = buildCrossDayBundle(days, const {});
      final recent = _recent(b);
      // Only the ordinary load term applies — no journal/context explanation.
      expect((recent[38] as Map)['masks'], ['load']);
      expect(recent.sublist(36).any((r) => (r as Map)['anomaly'] == true),
          isFalse,
          reason: 'persistence: no multi-night run, no anomaly flag');
      // (The RHR CUSUM's single-night red is pre-existing behaviour, gated at
      // the tier layer in the follow-up PR — not changed here.)
    });

    test('fixture 7: one short night -> sleep-debt context, no fire', () {
      final days = _days(41);
      days[38]['tst_min'] = 300; // 150 min short
      days[38]['rhr'] = 58.0; // +3 bpm
      days[38]['rmssd'] = 38.0; // −15 %
      final b = buildCrossDayBundle(days, const {});
      final recent = _recent(b);
      expect((recent[38] as Map)['masks'], contains('sleep_debt'));
      expect(recent.sublist(36).any((r) => (r as Map)['illness'] == true),
          isFalse);
      expect(recent.sublist(36).any((r) => (r as Map)['anomaly'] == true),
          isFalse);
    });
  });

  group('MUST fire (unexplained)', () {
    test('fixture 8: RHR↑ + resp↑ + temp↑ for 3 nights, no context -> all detectors fire',
        () {
      final days = _days(41);
      for (var i = 37; i <= 39; i++) {
        days[i]['rhr'] = 62.0; // +7 bpm
        days[i]['resp_rate'] = 17.0; // +3 br/min
        days[i]['skin_temp_adc'] = 3040.0; // +5 z
        days[i]['rmssd'] = 36.0; // −20 %
      }
      final b = buildCrossDayBundle(days, const {});
      final recent = _recent(b);
      // The CUSUM accumulates over the run: red lands within the 3 spike
      // nights (the exact night depends on the scaled-MAD baseline).
      expect(recent.sublist(37).any((r) => (r as Map)['illness'] == true),
          isTrue);
      expect(recent.sublist(37).any((r) => (r as Map)['anomaly'] == true),
          isTrue);
      expect(recent.sublist(37).any((r) => (r as Map)['temp'] == true), isTrue);
      // No journal explanation — only the ordinary (small) load term.
      expect((recent[38] as Map)['masks'], ['load']);
    });
  });

  group('degradation (honest, never green-by-silence)', () {
    test('fixture 10: skin temp withheld -> consensus continues on the remaining signals',
        () {
      final days = _days(41);
      for (final d in days) {
        d['skin_temp_adc'] = null;
        d['skin_temp_z'] = null;
      }
      for (var i = 37; i <= 39; i++) {
        days[i]['rhr'] = 65.0; // +10 bpm — beyond the small load term
        days[i]['rmssd'] = 30.0; // −33 %
      }
      final b = buildCrossDayBundle(days, const {});
      final recent = _recent(b);
      // RHR + HRV alone still flag the anomaly and the CUSUM…
      expect(recent.sublist(37).any((r) => (r as Map)['illness'] == true),
          isTrue);
      expect(recent.sublist(37).any((r) => (r as Map)['anomaly'] == true),
          isTrue);
      // …the temperature family is honestly NULL, not "normal"…
      expect(b['temp_illness'], isNull);
      expect((recent[38] as Map)['temp_residual'], isNull);
      // …and the calibration block says the temp signal is unavailable.
      final signals = (b['calibration'] as Map)['signals'] as Map;
      expect(signals['temp'], 0);
      expect(signals['rhr'], greaterThan(30));
    });

    test('fixture 11: under 7 valid nights -> stage 0 calibrating, zero findings',
        () {
      final days = _days(5);
      final b = buildCrossDayBundle(days, const {});
      expect((b['calibration'] as Map)['stage'], 0);
      expect((b['calibration'] as Map)['stage_label'], 'calibrating');
      expect((b['calibration'] as Map)['valid_nights'], 5);
      expect(_recent(b).any((r) => (r as Map)['illness'] == true), isFalse);
      expect(_recent(b).any((r) => (r as Map)['anomaly'] == true), isFalse);
      expect(_recent(b).any((r) => (r as Map)['temp'] == true), isFalse);
    });

    test('fixture 12: a 21-day wear gap drops the calibration stage by one', () {
      final days = _withGap();
      final b = buildCrossDayBundle(days, const {});
      final cal = b['calibration'] as Map;
      expect(cal['valid_nights'], 38);
      expect(cal['max_gap_days'], 21);
      expect(cal['gap_drop'], isTrue);
      expect(cal['stage'], 2); // 38 nights would be 3; the gap re-enters partial
    });
  });
}
