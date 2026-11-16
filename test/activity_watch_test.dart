// activity_watch.dart (PR 3): the inactivity watch and the recovery trend.
// Pure engine tests (goal boundaries, rest-state suppression, gap handling,
// the "despite normal load" gate) plus pipeline fixtures driving the real
// buildCrossDayBundle, asserting the bundle's `inactivity` / `recovery_trend`
// blocks. Both are informational cards — neither ever pushes.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/activity_watch.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';

String _d(int i) {
  final dt = DateTime(2024, 1, 1 + i);
  return '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}

List<String> _dates(int n) => [for (var i = 0; i < n; i++) _d(i)];

List<double?> _const(int n, double v) => [for (var i = 0; i < n; i++) v];

List<double?> _wobble(int n, double base, double amp) => [
      for (var i = 0; i < n; i++) base + ((i % 5) - 2) * amp,
    ];

void main() {
  group('inactivity watch', () {
    test('fires: 7 days well below usual AND under the weekly goal', () {
      final n = 40;
      final strain = _const(n, 8.0);
      for (var i = n - 7; i < n; i++) {
        strain[i] = 2.0;
      }
      final r = computeInactivity(
        dates: _dates(n),
        strain: strain,
        journalTagsByDate: const {},
      )!;
      expect(r['state'], 'firing');
      expect(r['days_below'], 7);
      expect(r['strain7'], 14.0);
      expect(r['goal'], kDefaultWeeklyActivityGoal);
      expect(r['date'], _d(n - 1));
    });

    test('goal boundary: strain7 == goal does not fire, goal+1 does', () {
      final n = 40;
      final strain = _const(n, 8.0);
      for (var i = n - 7; i < n; i++) {
        strain[i] = 3.0; // strain7 = 21, below usual (4.8)
      }
      final dates = _dates(n);
      final atGoal = computeInactivity(
          dates: dates,
          strain: strain,
          journalTagsByDate: const {},
          weeklyGoal: 21.0)!;
      expect(atGoal['state'], 'ok', reason: 'strictly below the goal only');
      final aboveGoal = computeInactivity(
          dates: dates,
          strain: strain,
          journalTagsByDate: const {},
          weeklyGoal: 22.0)!;
      expect(aboveGoal['state'], 'firing');
    });

    test('below the goal but NOT below usual -> no fire', () {
      final n = 40;
      final strain = _const(n, 8.0); // usual 8, below-at 4.8
      for (var i = n - 7; i < n; i++) {
        strain[i] = 6.0; // strain7 = 42 < 45, but 6 > 4.8 -> not below usual
      }
      final r = computeInactivity(
          dates: _dates(n), strain: strain, journalTagsByDate: const {})!;
      expect(r['state'], 'ok');
      expect(r['days_below'], 0);
    });

    test('explicit rest state (>=3 rest-day tags in the window) suppresses', () {
      final n = 40;
      final strain = _const(n, 8.0);
      for (var i = n - 7; i < n; i++) {
        strain[i] = 2.0;
      }
      final tags = <String, List<String>>{
        for (var i = n - 3; i < n; i++) _d(i): ['rest day'],
      };
      final r = computeInactivity(
          dates: _dates(n), strain: strain, journalTagsByDate: tags)!;
      expect(r['state'], 'rest');
      expect(r['rest_days'], 3);
    });

    test('a wear gap inside the 7-day window -> null, never a verdict', () {
      final n = 40;
      final strain = _const(n, 8.0);
      strain[n - 3] = null; // one unread day in the window
      for (var i = n - 7; i < n; i++) {
        if (strain[i] != null) strain[i] = 2.0;
      }
      expect(
          computeInactivity(
              dates: _dates(n), strain: strain, journalTagsByDate: const {}),
          isNull);
    });

    test('too little strain history -> calibrating, not green', () {
      final n = 10;
      final r = computeInactivity(
          dates: _dates(n),
          strain: _const(n, 2.0),
          journalTagsByDate: const {})!;
      expect(r['state'], 'calibrating');
    });
  });

  group('recovery trend', () {
    Map<String, dynamic> trend({
      required List<double?> rhr,
      required List<double?> hrv,
      required List<double?> strain,
      int stage = 3,
      List<bool>? unsettled,
    }) {
      final n = rhr.length;
      return computeRecoveryTrend(
        dates: _dates(n),
        unsettled: unsettled ?? List.filled(n, false),
        rhrResid: rhr,
        hrvResid: hrv,
        strain: strain,
        stage: stage,
      )!;
    }

    test('fires: HRV suppressed 7/7 nights, RHR +2.5 bpm, load flat', () {
      final n = 40;
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final strain = _const(n, 7.0);
      for (var i = n - 7; i < n; i++) {
        hrv[i] = 38.0; // z ~ -3.2
        rhr[i] = 57.5; // +2.5 over baseline median
      }
      final r = trend(rhr: rhr, hrv: hrv, strain: strain);
      expect(r['state'], 'firing');
      expect(r['days_suppressed'], 7);
      expect(r['rhr_delta_bpm'], greaterThanOrEqualTo(kTrendRhrRiseBpm));
      expect(r['date'], _d(n - 1));
    });

    test('rising load blocks it (the "despite normal load" gate)', () {
      final n = 40;
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final strain = _const(n, 7.0);
      for (var i = n - 7; i < n; i++) {
        hrv[i] = 38.0;
        rhr[i] = 57.5;
        strain[i] = 12.0; // load ROSE -> the suppression is explained by training
      }
      final r = trend(rhr: rhr, hrv: hrv, strain: strain);
      expect(r['state'], 'ok');
    });

    test('only 3 suppressed nights -> no fire (persistence)', () {
      final n = 40;
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final strain = _const(n, 7.0);
      for (var i = n - 3; i < n; i++) {
        hrv[i] = 38.0;
        rhr[i] = 57.5;
      }
      final r = trend(rhr: rhr, hrv: hrv, strain: strain);
      expect(r['state'], 'ok');
      expect(r['days_suppressed'], 3);
    });

    test('stage < 2 -> null (calibrating), never a verdict', () {
      final n = 40;
      expect(
          computeRecoveryTrend(
            dates: _dates(n),
            unsettled: List.filled(n, false),
            rhrResid: _wobble(n, 55, 1),
            hrvResid: _const(n, 38.0),
            strain: _const(n, 7.0),
            stage: 1,
          ),
          isNull);
    });

    test('unsettled nights are skipped, not read as clean', () {
      final n = 40;
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final strain = _const(n, 7.0);
      for (var i = n - 7; i < n; i++) {
        hrv[i] = 38.0;
        rhr[i] = 57.5;
      }
      final unsettled = List<bool>.filled(n, false);
      for (var i = n - 7; i < n; i++) {
        unsettled[i] = true; // the whole spike run is unsettled
      }
      final r = computeRecoveryTrend(
        dates: _dates(n),
        unsettled: unsettled,
        rhrResid: rhr,
        hrvResid: hrv,
        strain: strain,
        stage: 3,
      );
      // The window slides to the 7 settled nights before the spike: clean.
      expect(r == null || r['state'] == 'ok', isTrue);
    });
  });

  group('pipeline integration (buildCrossDayBundle)', () {
    List<Map<String, dynamic>> days(int n) => [
          for (var i = 0; i < n; i++)
            {
              'date': _d(i),
              'rhr': 55.0 + ((i % 5) - 2),
              'rmssd': 45.0 + ((i % 5) - 2) * 1.5,
              'readiness': 70.0,
              'resp_rate': 14.0 + ((i % 5) - 2) * 0.3,
              'skin_temp_z': ((i % 5) - 2) * 0.4,
              'skin_temp_adc': 3000.0 + ((i % 5) - 2) * 8.0,
              'skin_temp_family': 'gen4',
              'trimp': 80.0,
              'strain': 8.0,
              'tst_min': 450,
              'onset_sec': 23 * 3600,
              'wake_sec': 31 * 3600,
            },
        ];

    test('low-activity week with suppressed HRV and rising RHR -> both blocks fire',
        () {
      final ds = days(40);
      for (var i = 33; i < 40; i++) {
        ds[i]['strain'] = 2.0;
        ds[i]['rmssd'] = 38.0;
        ds[i]['rhr'] = 57.5;
      }
      final b = buildCrossDayBundle(ds, const {});
      final inact = b['inactivity'] as Map;
      expect(inact['state'], 'firing');
      expect(inact['days_below'], 7);
      final trend = b['recovery_trend'] as Map;
      expect(trend['state'], 'firing');
      expect(trend['days_suppressed'], 7);
    });

    test('the same nights with RISING load -> recovery trend stays quiet', () {
      final ds = days(40);
      for (var i = 33; i < 40; i++) {
        ds[i]['strain'] = 14.0; // load rose
        ds[i]['rmssd'] = 38.0;
        ds[i]['rhr'] = 57.5;
      }
      final b = buildCrossDayBundle(ds, const {});
      expect((b['recovery_trend'] as Map)['state'], 'ok');
      expect((b['inactivity'] as Map)['state'], 'ok');
    });

    test('rest-day journal tags suppress the inactivity watch end-to-end', () {
      final ds = days(40);
      for (var i = 33; i < 40; i++) {
        ds[i]['strain'] = 2.0;
      }
      final journal = <String, Map<String, dynamic>>{
        for (var i = 37; i < 40; i++) _d(i): {
          'tags': ['rest day'],
        },
      };
      final b = buildCrossDayBundle(ds, const {}, journalByDate: journal);
      expect((b['inactivity'] as Map)['state'], 'rest');
    });

    test('the weekly goal comes from the profile', () {
      final ds = days(40);
      for (var i = 33; i < 40; i++) {
        ds[i]['strain'] = 3.0; // strain7 = 21
      }
      final bLow = buildCrossDayBundle(ds, const {});
      expect((bLow['inactivity'] as Map)['state'], 'firing'); // 21 < 45
      final bHigh =
          buildCrossDayBundle(ds, {'weekly_activity_goal': 20.0});
      expect((bHigh['inactivity'] as Map)['state'], 'ok'); // 21 >= 20
    });
  });
}
