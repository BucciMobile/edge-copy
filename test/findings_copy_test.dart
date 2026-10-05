// What the health findings SAY, and on which number.
//
// The illness finding comes from a CUSUM on nightly resting heart rate alone.
// The detector's own contract says it reports a state, not a diagnosis, and
// that nothing may say "illness" without corroboration from a second signal.
// The in-app illness cards already say "This watches one signal only". The
// shared sentence the push and the log print must not claim more.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/data/day_label.dart';

void main() {
  test('the illness sentence claims no signal the detector does not read', () {
    const f = Finding(FindingKind.illness, '2026-10-01');
    expect(f.detail.toLowerCase(), isNot(contains('hrv')));
    expect(f.detail, contains('one signal only'));
    expect(f.title.toLowerCase(), isNot(contains('illness')));
  });

  // A red CUSUM state is accumulated EVIDENCE, not a run of high nights: one
  // very high night followed by an ordinary one is red on the ordinary night
  // (the accumulator only clears after two normal nights). The sentence the
  // push and the log print for it must not claim a streak.
  test('the illness sentence claims no streak a red state does not guarantee',
      () {
    final dates = [
      for (var i = 0; i < 30; i++)
        dayLabelOf(DateTime(2026, 9, 1 + i)),
    ];
    final rhr = <double?>[
      for (var i = 0; i < 28; i++) 53.0 + i % 5, // 53..57 baseline
      74, // one high night
      55, // then an ordinary one
    ];
    final out = ana.illnessCusum(dates, rhr);
    expect(out[28].state, ana.IllnessState.yellow);
    expect(out.last.state, ana.IllnessState.red,
        reason: 'the premise: red on a night that is itself normal');

    final f = Finding(FindingKind.illness, out.last.date);
    final copy = '${f.title} ${f.detail}'.toLowerCase();
    for (final claim in [
      'nights running',
      'consecutive',
      'in a row',
      'several nights',
      'running high',
    ]) {
      expect(copy, isNot(contains(claim)), reason: claim);
    }
    expect(f.detail, contains('This watches one signal only.'));
    expect(f.detail, contains('It names a pattern, not a cause.'));
  });

  // The in-app illness cards (and the rough-night note naming the same
  // verdict) sit beside the push and say the same thing in six languages. A
  // card that kept "several nights in a row" next to a push that dropped it
  // would contradict it — so every illness-card string, in every locale, is
  // held to the same rule.
  test('no illness-card string, in any locale, claims a streak', () {
    // The streak and "sustained" phrasings each locale used, plus the
    // English ones in general.
    const banned = {
      'en': [
        'in a row',
        'consecutive',
        'several nights',
        'nights running',
        'running above',
        'running high',
        'sustained',
      ],
      'de': [
        'in folge',
        'mehrere nächte',
        'seit einiger zeit',
        'zuletzt über',
        'anhaltend',
      ],
      'es': [
        'seguidas',
        'varias noches',
        'se ha mantenido',
        'ha estado por',
        'sostenida',
      ],
      'fr': [
        "d'affilée",
        'plusieurs nuits',
        'se maintient',
        'est restée',
        'soutenue',
      ],
      'hi': ['लगातार', 'बनी हुई', 'बनी रही'],
      // Not bare 持续: the advice line rightly says "if it continues".
      'zh': ['连续', '一直高于', '持续高于', '持续上升'],
    };
    for (final MapEntry(key: locale, value: phrases) in banned.entries) {
      final arb = (jsonDecode(
              File('lib/l10n/app_$locale.arb').readAsStringSync()) as Map)
          .cast<String, dynamic>();
      final illness = {
        for (final e in arb.entries)
          if (RegExp(r'^((home|health)Illness|roughNightIllness)')
              .hasMatch(e.key))
            e.key: (e.value as String).toLowerCase(),
      };
      expect(illness, isNotEmpty, reason: locale);
      for (final MapEntry(key: k, value: v) in illness.entries) {
        for (final phrase in phrases) {
          expect(v, isNot(contains(phrase)), reason: '$locale $k');
        }
      }
    }
  });
}
