// The PR-3 trend cards (trendCards in tier_card.dart): inactivity watch and
// recovery trend, informational only, today/yesterday gate, suppressed while
// the illness state is active, honest nothing otherwise — plus the l10n keys
// in every locale.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/tier_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _today = '2024-02-10';

Map<String, dynamic> _inactivity(String date, {String state = 'firing'}) => {
      'state': state,
      'date': date,
      'days_below': 9,
      'strain7': 14.0,
      'goal': 45.0,
      'usual_daily': 8.0,
    };

Map<String, dynamic> _trend(String date, {String state = 'firing'}) => {
      'state': state,
      'date': date,
      'days_suppressed': 6,
      'hrv_z': -2.1,
      'rhr_delta_bpm': 2.4,
      'load_ratio': 0.9,
    };

Future<void> _pump(
  WidgetTester tester,
  Locale locale, {
  Object? inactivity,
  Object? recoveryTrend,
  bool illnessActive = false,
}) =>
    tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppShell(
        builder: (c, d) {
          final cards = trendCards(c,
              today: _today,
              inactivity: inactivity,
              recoveryTrend: recoveryTrend,
              illnessActive: illnessActive);
          return Scaffold(
            body: Column(
              children: [
                ...cards,
                if (cards.isEmpty) const Text('none'),
              ],
            ),
          );
        },
      ),
    ));

void main() {
  testWidgets('both cards show when firing, dated today', (tester) async {
    await _pump(tester, const Locale('en'),
        inactivity: _inactivity(_today), recoveryTrend: _trend(_today));
    await tester.pumpAndSettle();
    expect(find.text('Well below your usual activity'), findsOneWidget);
    expect(find.textContaining('9 days'), findsOneWidget);
    expect(find.text('Recovery trend below your usual'), findsOneWidget);
    expect(find.textContaining('6 nights'), findsOneWidget);
  });

  testWidgets('yesterday still shows; 3 days old does not', (tester) async {
    await _pump(tester, const Locale('en'),
        inactivity: _inactivity('2024-02-09'), recoveryTrend: _trend('2024-02-09'));
    await tester.pumpAndSettle();
    expect(find.text('Well below your usual activity'), findsOneWidget);

    await _pump(tester, const Locale('en'), inactivity: _inactivity('2024-02-07'));
    await tester.pumpAndSettle();
    expect(find.text('none'), findsOneWidget);
  });

  testWidgets('state ok / rest show nothing — never a green card', (tester) async {
    await _pump(tester, const Locale('en'), inactivity: _inactivity(_today, state: 'ok'));
    await tester.pumpAndSettle();
    expect(find.text('none'), findsOneWidget);

    await _pump(tester, const Locale('en'), inactivity: _inactivity(_today, state: 'rest'));
    await tester.pumpAndSettle();
    expect(find.text('none'), findsOneWidget);
  });

  testWidgets('illness state active -> both cards stand down', (tester) async {
    await _pump(tester, const Locale('en'),
        inactivity: _inactivity(_today),
        recoveryTrend: _trend(_today),
        illnessActive: true);
    await tester.pumpAndSettle();
    expect(find.text('none'), findsOneWidget);
  });

  testWidgets('a German user gets the German cards', (tester) async {
    await _pump(tester, const Locale('de'),
        inactivity: _inactivity(_today), recoveryTrend: _trend(_today));
    await tester.pumpAndSettle();
    expect(find.text('Weit unter deiner üblichen Aktivität'), findsOneWidget);
    expect(find.text('Erholungstrend unter deinem üblichen Maß'), findsOneWidget);
    expect(find.text('Well below your usual activity'), findsNothing);
  });

  test('every locale has the trend-card and goal keys, translated', () {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final loc in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(loc);
      expect(l.inactivityCardTitle, isNotEmpty, reason: '$loc');
      expect(l.inactivityCardBody(9, 14, 45), isNotEmpty, reason: '$loc');
      expect(l.recoveryCardTitle, isNotEmpty, reason: '$loc');
      expect(l.recoveryCardBody(6), isNotEmpty, reason: '$loc');
      expect(l.activityGoalSection, isNotEmpty, reason: '$loc');
      expect(l.activityGoalRow, isNotEmpty, reason: '$loc');
      expect(l.activityGoalHint, isNotEmpty, reason: '$loc');
      expect(l.activityGoalInvalid(10, 147), isNotEmpty, reason: '$loc');
      if (loc.languageCode != 'en') {
        expect(l.inactivityCardTitle, isNot(en.inactivityCardTitle),
            reason: '$loc should be translated');
        expect(l.recoveryCardTitle, isNot(en.recoveryCardTitle),
            reason: '$loc should be translated');
      }
    }
  });
}
