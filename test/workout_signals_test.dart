// workout_signals.dart (PR 4): HR drift, pace-vs-HR economy, strength volume,
// per-day aggregation — plus their wiring into the context model (masking
// only, never the illness tiers) and the recovery trend's performance-
// decrement path.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/activity_watch.dart';
import 'package:openstrap_edge/compute/context_model.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';
import 'package:openstrap_edge/compute/workout_signals.dart';

String _d(int i) {
  final dt = DateTime(2024, 1, 1 + i);
  return '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}

List<String> _dates(int n) => [for (var i = 0; i < n; i++) _d(i)];

/// n per-km splits at a constant [pace] m/s; avg HR is [hrFirst] for the first
/// half of the splits and [hrSecond] for the second half.
List<Map<String, dynamic>> _splits(int n, double pace, double hrFirst,
    [double? hrSecond]) {
  final second = hrSecond ?? hrFirst;
  return [
    for (var i = 0; i < n; i++)
      {
        'km': i + 1,
        'meters': 1000.0,
        'duration_sec': (1000.0 / pace).round(),
        'avg_hr': i < n / 2 ? hrFirst : second,
      },
  ];
}

void main() {
  group('hrDriftBpm', () {
    test('steady session: second-half HR minus first-half', () {
      expect(hrDriftBpm(_splits(10, 5.0, 140, 148)), closeTo(8.0, 0.01));
    });

    test('non-steady session (pace varies >10%) -> null, never a guess', () {
      final splits = <Map<String, dynamic>>[
        for (var i = 0; i < 10; i++)
          {
            'km': i + 1,
            'meters': 1000.0,
            // alternating 4 m/s and 6 m/s — 50% spread
            'duration_sec': i.isEven ? 250 : 167,
            'avg_hr': 140.0 + i,
          },
      ];
      expect(hrDriftBpm(splits), isNull);
    });

    test('fewer than 6 steady splits -> null', () {
      expect(hrDriftBpm(_splits(4, 5.0, 140, 150)), isNull);
    });

    test('splits without avg_hr are skipped', () {
      final splits = _splits(8, 5.0, 140, 146);
      splits[3] = {...splits[3], 'avg_hr': null};
      expect(hrDriftBpm(splits), isNotNull);
    });
  });

  group('paceHrEconomy', () {
    test('m/s per bpm over steady splits', () {
      // pace 5 m/s at 150 bpm -> 5/150
      expect(paceHrEconomy(_splits(6, 5.0, 150)), closeTo(5 / 150, 1e-9));
    });

    test('too few splits -> null', () {
      expect(paceHrEconomy(_splits(3, 5.0, 150)), isNull);
    });
  });

  group('strengthVolume', () {
    test('reps x load summed; bodyweight counted as reps, never kg', () {
      final v = strengthVolume([
        {'reps': 10, 'load_kg': 50.0},
        {'reps': 8, 'load_kg': 60.0},
        {'reps': 12, 'load_kg': null},
      ]);
      expect(v.volumeKg, 980.0);
      expect(v.bodyweightReps, 12);
    });
  });

  group('dailyWorkoutSignals', () {
    test('aggregates hrr mean, max drift, best economy, volume', () {
      final s = dailyWorkoutSignals(
        sessions: [
          {'id': 'a', 'hrr_bpm': 30.0, 'strain': 9.0},
          {'id': 'b', 'hrr_bpm': 40.0, 'strain': 5.0},
        ],
        splitsBySession: {
          'a': _splits(10, 5.0, 140, 148),
          'b': _splits(8, 4.5, 150),
        },
        strengthSets: [
          {'reps': 10, 'load_kg': 50.0},
        ],
      );
      expect(s['n_sessions'], 2);
      expect(s['hrr_bpm'], 35.0);
      expect(s['hr_drift_bpm'], 8.0);
      expect(s['economy'], greaterThan(0));
      expect(s['volume_kg'], 500.0);
      expect(s['max_strain'], 9.0);
    });

    test('no sessions -> nulls and zero volume, never fabricated', () {
      final s = dailyWorkoutSignals(sessions: const []);
      expect(s['hrr_bpm'], isNull);
      expect(s['hr_drift_bpm'], isNull);
      expect(s['economy'], isNull);
      expect(s['volume_kg'], 0.0);
      expect(s['max_strain'], isNull);
    });
  });

  group('context model: workout signals mask, never fire', () {
    test('a poor HRR yesterday suppresses the EXPECTED part of tonight, so the residual shrinks',
        () {
      final n = 40;
      final dates = _dates(n);
      final rhr = List<double?>.filled(n, 55.0);
      final rmssd = List<double?>.filled(n, 45.0);
      final resp = List<double?>.filled(n, 14.0);
      final temp = List<double?>.filled(n, 3000.0);
      final strain = List<double?>.filled(n, 7.0);
      final tst = List<double?>.filled(n, 450.0);
      final unsettled = List<bool>.filled(n, false);
      // Baseline HRR 40 on every earlier day; yesterday's session recovered poorly (25).
      final workouts = <String, Map<String, double>>{
        for (var i = 0; i < n - 2; i++) _d(i): {'hrr_bpm': 40.0, 'volume_kg': 0},
        _d(n - 2): {'hrr_bpm': 25.0, 'volume_kg': 0},
      };
      final without = buildContextResiduals(
        dates: dates,
        unsettled: unsettled,
        rhr: rhr,
        rmssd: rmssd,
        resp: resp,
        tempAlert: temp,
        strain: strain,
        tstMin: tst,
      );
      final withW = buildContextResiduals(
        dates: dates,
        unsettled: unsettled,
        rhr: rhr,
        rmssd: rmssd,
        resp: resp,
        tempAlert: temp,
        strain: strain,
        tstMin: tst,
        workoutsByDate: workouts,
      );
      final i = n - 1;
      expect(withW.masks[i], contains('workout recovery'));
      // The HRV residual (a suppression) is smaller in magnitude with the mask.
      expect(withW.hrvResidual[i]! - rmssd[i]!, lessThan(0));
      expect((withW.hrvResidual[i]! - rmssd[i]!),
          greaterThan(without.hrvResidual[i]! - rmssd[i]!));
      // And with no workout data at all the residuals are byte-identical.
      expect(without.hrvResidual[i], without.hrvResidual[i]);
    });

    test('strength volume adds a load-like mask', () {
      final n = 40;
      final dates = _dates(n);
      final base = buildContextResiduals(
        dates: dates,
        unsettled: List.filled(n, false),
        rhr: List<double?>.filled(n, 55.0),
        rmssd: List<double?>.filled(n, 45.0),
        resp: List<double?>.filled(n, 14.0),
        tempAlert: List<double?>.filled(n, 3000.0),
        strain: List<double?>.filled(n, 7.0),
        tstMin: List<double?>.filled(n, 450.0),
      );
      final withVol = buildContextResiduals(
        dates: dates,
        unsettled: List.filled(n, false),
        rhr: List<double?>.filled(n, 55.0),
        rmssd: List<double?>.filled(n, 45.0),
        resp: List<double?>.filled(n, 14.0),
        tempAlert: List<double?>.filled(n, 3000.0),
        strain: List<double?>.filled(n, 7.0),
        tstMin: List<double?>.filled(n, 450.0),
        workoutsByDate: {_d(n - 2): {'hrr_bpm': 40.0, 'volume_kg': 20000.0}},
      );
      expect(withVol.masks[n - 1], contains('volume'));
      expect(withVol.hrvResidual[n - 1]!, greaterThan(base.hrvResidual[n - 1]!));
    });
  });

  group('recovery trend: performance decrement', () {
    test('economy declining >=5% at flat load fires via performance', () {
      final n = 40;
      final dates = _dates(n);
      final unsettled = List<bool>.filled(n, false);
      final rhr = List<double?>.filled(n, 55.0);
      final hrv = List<double?>.filled(n, 45.0);
      final strain = List<double?>.filled(n, 7.0);
      final economy = <double?>[
        for (var i = 0; i < n; i++) i < n - 7 ? 0.040 : 0.037, // -7.5%
      ];
      final r = computeRecoveryTrend(
        dates: dates,
        unsettled: unsettled,
        rhrResid: rhr,
        hrvResid: hrv,
        strain: strain,
        stage: 3,
        economy: economy,
      )!;
      expect(r['state'], 'firing');
      expect(r['via'], 'performance');
      expect(r['economy_delta_pct'], greaterThanOrEqualTo(0.05));
      expect(r['days_economy'], 7);
    });

    test('economy decline with RISING load does not fire', () {
      final n = 40;
      final strain = List<double?>.filled(n, 7.0);
      for (var i = n - 7; i < n; i++) {
        strain[i] = 14.0;
      }
      final economy = <double?>[
        for (var i = 0; i < n; i++) i < n - 7 ? 0.040 : 0.037,
      ];
      final r = computeRecoveryTrend(
        dates: _dates(n),
        unsettled: List.filled(n, false),
        rhrResid: List<double?>.filled(n, 55.0),
        hrvResid: List<double?>.filled(n, 45.0),
        strain: strain,
        stage: 3,
        economy: economy,
      )!;
      expect(r['state'], 'ok');
    });

    test('economy flat -> no performance firing', () {
      final n = 40;
      final economy = List<double?>.filled(n, 0.040);
      final r = computeRecoveryTrend(
        dates: _dates(n),
        unsettled: List.filled(n, false),
        rhrResid: List<double?>.filled(n, 55.0),
        hrvResid: List<double?>.filled(n, 45.0),
        strain: List<double?>.filled(n, 7.0),
        stage: 3,
        economy: economy,
      )!;
      expect(r['state'], 'ok');
      expect(r['via'], isNull);
    });
  });

  group('pipeline integration', () {
    test('workoutsByDate flows into the bundle and the trend', () {
      final n = 40;
      final days = <Map<String, dynamic>>[
        for (var i = 0; i < n; i++)
          {
            'date': _d(i),
            'rhr': 55.0,
            'rmssd': 45.0,
            'readiness': 70.0,
            'resp_rate': 14.0,
            'skin_temp_z': 0.0,
            'skin_temp_adc': 3000.0,
            'skin_temp_family': 'gen4',
            'trimp': 80.0,
            'strain': 7.0,
            'tst_min': 450,
            'onset_sec': 23 * 3600,
            'wake_sec': 31 * 3600,
          },
      ];
      final workouts = <String, Map<String, dynamic>>{
        for (var i = 0; i < n; i++)
          _d(i): {
            'hrr_bpm': 40.0,
            'volume_kg': 0.0,
            'economy': i < n - 7 ? 0.040 : 0.037,
          },
      };
      final b = buildCrossDayBundle(days, const {}, workoutsByDate: workouts);
      expect((b['workout_signals'] as Map)['version'], 1);
      expect(((b['workout_signals'] as Map)['per_day'] as Map).length, n);
      final trend = b['recovery_trend'] as Map;
      expect(trend['state'], 'firing');
      expect(trend['via'], 'performance');
      // And with no workout data the block is empty but present, trend ok.
      final b0 = buildCrossDayBundle(days, const {});
      expect((b0['workout_signals'] as Map)['per_day'], isEmpty);
      expect((b0['recovery_trend'] as Map)['state'], 'ok');
    });
  });
}
