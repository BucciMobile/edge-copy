// VO₂max method-core tests — pinned against the analytics pin
// (pubspec.yaml `openstrap_analytics` @ its pinned SHA; formula lives in
// analytics `lib/src/onehz/clinical/vo2max.dart`) and against the
// hand-derived reference cases in docs/VO2MAX.md.
//
// What these tests DO pin:
//   • the exact ACSM running/walking equation outputs, incl. unit conversion
//     (m/s -> m/min is the caller's job; km/h -> m/min is pinned here) and
//     percent -> grade-fraction handling.
//   • the Swain %HRR -> %VO2R extrapolation VO2max = 3.5 + (VO2sub-3.5)/%HRR.
//   • method selection: which estimate tier / abstention reason each input
//     shape produces, incl. contradictory HRs and non-finite inputs.
//
// What they deliberately DO NOT pin:
//   • Uth et al. (2004) HRmax/HRrest (15.3 * HRmax/HRrest) — NOT IMPLEMENTED.
//     It reduces to a rescaled resting HR (see crossday_pipeline.dart's
//     CV-02 note) and the repo deleted it deliberately; the reference case
//     (HRmax 180, HRrest 60 -> 45.9) is asserted ABSENT here as a regression
//     guard against anyone re-adding it silently.
//   • Cooper 12-min test — NOT IMPLEMENTED: a normal session's arbitrary
//     12-minute window is not a documented Cooper protocol, so the formula
//     must not run on this data at all.
//   • physiological validity — these are arithmetic pins, not clinical ones.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_analytics/onehz.dart' as ana;

import 'package:openstrap_edge/compute/vo2max_activity_gate.dart';
import 'dart:io';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/activity/summary.dart'
    show vo2maxAbsenceText;

/// lib/**.dart sources, for the static no-Uth guard. The test file is not
/// under lib/, so its own mention of 15.3 never trips the check.
List<File> _edgeLibSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  group('ACSM running equation (the pinned analytics formula)', () {
    test('flat run: speed 3.03 m/s at 72% HRR , -> 54.03 ml/kg/min', () {
      // 1000 m / 330 s = 3.0303 m/s = 181.82 m/min.
      // VO2sub = 0.2*181.82 + 3.5 = 39.864; %HRR = 95/132 = 0.71970.
      // VO2max = 3.5 + 36.3636/0.719697 = 54.026.
      final m = ana.vo2maxSubmaxEstimate(
        speedMps: 1000 / 330,
        avgHrBpm: 150,
        boutDurationSec: 330,
        restingHrBpm: 55,
        hrMaxBpm: 187,
      );
      expect(m.present, isTrue);
      expect(m.value!, closeTo(54.026, 0.001));
      expect(m.tier, ana.Tier.estimate);
    });

    test('km/h -> m/min unit conversion feeds the equation correctly', () {
      // 10.9 km/h = 10 900 m / 60 min = 181.67 m/min — same bout as above
      // within rounding, and NOT 10.9 m/min (the km/h-as-m/min bug).
      const kmH = 10.909;
      final mMin = kmH * 1000 / 60;
      expect(mMin, closeTo(181.8, 0.1));
      final m = ana.vo2maxSubmaxEstimate(
        speedMps: kmH / 3.6,
        avgHrBpm: 150,
        boutDurationSec: 330,
        restingHrBpm: 55,
        hrMaxBpm: 187,
      );
      expect(m.present, isTrue);
      expect(m.value!, closeTo(54.026, 0.001));
    });

    test('grade percent -> fraction: 5% uphill raises the estimate', () {
      final flat = ana.vo2maxSubmaxEstimate(
        speedMps: 1000 / 330,
        avgHrBpm: 150,
        boutDurationSec: 330,
        restingHrBpm: 55,
        hrMaxBpm: 187,
      );
      final graded = ana.vo2maxSubmaxEstimate(
        speedMps: 1000 / 330,
        avgHrBpm: 150,
        boutDurationSec: 330,
        restingHrBpm: 55,
        hrMaxBpm: 187,
        gradePercent: 5,
      );
      // Running grade term: 0.9 * 181.82 * 0.05 = +8.18 ml/kg/min submax.
      // (5 must enter as 0.05, not 5 — the percent-vs-fraction bug.)
      expect(graded.value! - flat.value!, greaterThan(8.0));
      expect(graded.inputs_used, contains('workout_grade'));
    });

    test('walking bout (<2 m/s) uses the walking equation', () {
      // 1.39 m/s = 83.3 m/min: VO2sub = 0.1*83.3 + 3.5 = 11.83;
      // %HRR = (150-55)/132 = 0.7197 -> VO2max = 3.5 + 8.33/0.7197 = 15.07.
      final m = ana.vo2maxSubmaxEstimate(
        speedMps: 1000 / 720,
        avgHrBpm: 150,
        boutDurationSec: 720,
        restingHrBpm: 55,
        hrMaxBpm: 187,
      );
      expect(m.present, isTrue);
      expect(m.value!, closeTo(15.079, 0.001));
    });
  });

  group('invalid / contradictory / non-finite inputs abstain', () {
    test('non-finite speed abstains', () {
      final m = ana.vo2maxSubmaxEstimate(
        speedMps: double.nan,
        avgHrBpm: 150,
        boutDurationSec: 330,
        restingHrBpm: 55,
        hrMaxBpm: 187,
      );
      expect(m.present, isFalse);
    });

    test('contradictory HRs (resting >= max) abstain, never divide by <=0', () {
      final m = ana.vo2maxSubmaxEstimate(
        speedMps: 3.0,
        avgHrBpm: 150,
        boutDurationSec: 330,
        restingHrBpm: 190,
        hrMaxBpm: 187,
      );
      expect(m.present, isFalse);
    });

    test('negative speed and zero-length bouts abstain', () {
      for (final speed in [0.0, -3.0]) {
        final m = ana.vo2maxSubmaxEstimate(
          speedMps: speed,
          avgHrBpm: 150,
          boutDurationSec: 330,
          restingHrBpm: 55,
          hrMaxBpm: 187,
        );
        expect(m.present, isFalse, reason: 'speed $speed');
      }
      final short = ana.vo2maxSubmaxEstimate(
        speedMps: 3.0,
        avgHrBpm: 150,
        boutDurationSec: 0,
        restingHrBpm: 55,
        hrMaxBpm: 187,
      );
      expect(short.present, isFalse);
    });

    test('HRmax == HRrest (zero reserve) abstains', () {
      final m = ana.vo2maxSubmaxEstimate(
        speedMps: 3.0,
        avgHrBpm: 150,
        boutDurationSec: 330,
        restingHrBpm: 187,
        hrMaxBpm: 187,
      );
      expect(m.present, isFalse);
    });
  });

  group('method selection: NOT-implemented candidates stay out', () {
    // NOTE on the LIMIT of this guard: it pins that the ONE estimator the
    // edge calls cannot produce a value from resting numbers alone (no
    // bout, no value). It does NOT and cannot prove that no other code
    // path anywhere implements 15.3*HRmax/HRrest — that is a
    // whole-codebase property. The static half of that property is
    // asserted separately (see the 'no Uth formula in edge sources'
    // test below); this one pins the analytics surface only.
    test('Uth HRmax/HRrest (15.3*HRmax/HRrest) is NOT part of the surface', () {
      const uthResult = 15.3 * (180 / 60); // = 45.9, the would-be value
      expect(uthResult, closeTo(45.9, 1e-9));
      final m = ana.vo2maxSubmaxEstimate(
        speedMps: 0,
        avgHrBpm: 180,
        boutDurationSec: 0,
        restingHrBpm: 60,
        hrMaxBpm: 180,
      );
      expect(m.present, isFalse);
    });

    test('no Uth formula in EDGE sources (static grep-level guard)', () {
      // The honest half of the absence claim: the shipped edge code under
      // lib/ contains no 15.3 coefficient and no vo2max symbol that could
      // implement the RHR-ratio method. Run against the repo on disk, not
      // against this test file itself (which legitimately MENTIONS 15.3).
      // Comments legitimately MENTION the deleted method (its removal
      // is part of this repo's history); only CODE lines may not contain
      // the coefficient. Crude but honest about what it proves: a grep
      // over stripped lines, not a semantic analysis.
      final edge = _edgeLibSources();
      for (final f in edge) {
        for (final line in f.readAsLinesSync()) {
          final code = line.split('//').first;
          expect(
            code.contains('15.3'),
            isFalse,
            reason: 'Uth coefficient in ${f.path}: $line',
          );
          expect(
            code.contains('hrMax / rhr'),
            isFalse,
            reason: 'RHR-ratio in ${f.path}: $line',
          );
        }
      }
    });
  });

  group('activity gate (ACSM is foot-locomotion only)', () {
    test('walk/run/hike types are eligible, case/whitespace-insensitively', () {
      for (final t in ['run', 'Running', ' walk ', 'HIKE']) {
        expect(vo2maxEligibleActivity(t), isTrue, reason: t);
      }
    });

    test('cycle/swim/strength/null/unknown types are rejected', () {
      for (final t in ['cycle', 'swim', 'strength', null, '', 'golf']) {
        expect(vo2maxEligibleActivity(t), isFalse, reason: '$t');
      }
    });
  });

  group('absence codes map to prose, never leak snake_case', () {
    test('every known code has prose without an underscore', () {
      for (final code in [
        'unsupported_activity',
        'no_route',
        'route_too_short',
        'no_completed_km_split',
        'no_steady_hr_for_split',
        'no_qualifying_bout',
        // History-pass codes — shared storage vocabulary; each needs prose.
        'no_hr_max_available',
        'no_resting_hr_available',
        // A storage/route read failure, not a physiology abstention.
        'estimation_unavailable',
      ]) {
        final text = vo2maxAbsenceText(code);
        expect(text, isNotNull, reason: code);
        expect(text!.contains('_'), isFalse, reason: code);
      }
    });

    test('unknown codes fall back to a generic line, null stays null', () {
      expect(vo2maxAbsenceText('something_new'), isNotNull);
      expect(vo2maxAbsenceText(null), isNull);
    });
  });

  // L10N: every absence code must resolve to localized prose in EVERY
  // supported locale — the ARB files carry one key per code, and a locale
  // missing a key would fall back to English at runtime (acceptable), but a
  // MISSING ARB ENTRY would break gen-l10n. The generated lookup is driven
  // directly so no widget tree is needed.
  group('absence codes are localized in every supported locale', () {
    final codes = <String>[
      'unsupported_activity',
      'no_route',
      'route_too_short',
      'no_completed_km_split',
      'no_steady_hr_for_split',
      'no_qualifying_bout',
      'no_hr_max_available',
      'no_resting_hr_available',
      'equation_domain_ambiguous',
      'estimation_unavailable',
    ];
    for (final locale in AppLocalizations.supportedLocales) {
      test('locale ${locale.languageCode}: every code has localized prose', () {
        final l = lookupAppLocalizations(locale);
        for (final code in codes) {
          final text = vo2maxAbsenceText(code, l);
          expect(text, isNotNull, reason: '$code / ${locale.languageCode}');
          expect(
            text!.contains('_'),
            isFalse,
            reason:
                '$code leaked storage vocabulary in '
                '${locale.languageCode}',
          );
          expect(text, isNotEmpty, reason: code);
        }
        // The fallback line localizes too, and null stays null.
        expect(vo2maxAbsenceText('something_new', l), isNotNull);
        expect(vo2maxAbsenceText(null, l), isNull);
      });
    }
  });
}
