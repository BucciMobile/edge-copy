// The tier card (lib/ui2/screens/tier_card.dart) follows the illness-card
// freshness rule: dated by the night it is about, today/yesterday only, and
// never green-by-silence — while calibrating it says so, and while the
// illness state is active it stands down. Plus the check-in notification copy
// localized at the OS boundary (display_text.dart), including the
// parse-back of the interpolated streak.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/tier_engine.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/display_text.dart';
import 'package:openstrap_edge/notify/checkin.dart';
import 'package:openstrap_edge/ui2/screens/checkin_sheet.dart';
import 'package:openstrap_edge/ui2/screens/tier_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _today = '2024-02-10';

Map<String, dynamic> _tiers(
  String date, {
  int tier = 2,
  int streak = 3,
  int stage = 3,
  int valid = 35,
  List<String> signals = const ['rhr', 'hrv'],
}) =>
    {
      'date': date,
      'tier': tier,
      'signals': signals,
      'streak': streak,
      'constellation': tier >= 3,
      'stage': stage,
      'valid_nights': valid,
      'z': <String, double?>{'rhr': 4.7, 'hrv': -4.0, 'resp': null, 'temp': null},
    };

Future<void> _pump(
  WidgetTester tester,
  Locale locale,
  Object? tiers, {
  bool showCalibration = false,
  bool illnessActive = false,
}) =>
    tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppShell(
        builder: (c, d) => Scaffold(
          body: tierCard(c, tiers,
                  today: _today,
                  showCalibration: showCalibration,
                  illnessActive: illnessActive) ??
              const Text('none'),
        ),
      ),
    ));

void main() {
  testWidgets('deviation card shows today and yesterday, never older', (tester) async {
    await _pump(tester, const Locale('en'), _tiers(_today));
    await tester.pumpAndSettle();
    expect(find.text('Off your usual baseline'), findsOneWidget);
    expect(find.textContaining('3 nights'), findsOneWidget);

    await _pump(tester, const Locale('en'), _tiers('2024-02-09')); // yesterday
    await tester.pumpAndSettle();
    expect(find.text('Off your usual baseline'), findsOneWidget);

    await _pump(tester, const Locale('en'), _tiers('2024-02-07')); // 3 days old
    await tester.pumpAndSettle();
    expect(find.text('none'), findsOneWidget,
        reason: 'stale verdicts live in Observations, not on the card');
  });

  testWidgets('calibrating card is honest while stage < 3; nothing when off',
      (tester) async {
    await _pump(tester, const Locale('en'), _tiers(_today, tier: 0, streak: 0),
        showCalibration: true, );
    await tester.pumpAndSettle();
    // stage 3 here, so no calibration card even with showCalibration:
    expect(find.text('none'), findsOneWidget);

    await _pump(tester, const Locale('en'), _tiers(_today, tier: 0, streak: 0, stage: 2, valid: 23),
        showCalibration: true);
    await tester.pumpAndSettle();
    expect(find.text('Learning your baseline'), findsOneWidget);
    expect(find.textContaining('23 of 30 nights'), findsOneWidget);

    await _pump(tester, const Locale('en'), _tiers(_today, tier: 0, streak: 0, stage: 2, valid: 23),
        showCalibration: false);
    await tester.pumpAndSettle();
    expect(find.text('none'), findsOneWidget,
        reason: 'Home does not show calibration; Health does');
  });

  testWidgets('illness state active: the card stands down instead of re-warning',
      (tester) async {
    await _pump(tester, const Locale('en'), _tiers(_today), illnessActive: true);
    await tester.pumpAndSettle();
    expect(find.text('Taking it easy'), findsOneWidget);
    expect(find.text('Off your usual baseline'), findsNothing);
  });

  testWidgets('a German user gets the German card', (tester) async {
    await _pump(tester, const Locale('de'), _tiers(_today));
    await tester.pumpAndSettle();
    expect(find.text('Abseits deiner Baseline'), findsOneWidget);
    expect(find.textContaining('3 Nächte'), findsOneWidget);
    expect(find.text('Off your usual baseline'), findsNothing);
  });

  testWidgets('non-map tiers -> null, never a green card', (tester) async {
    await _pump(tester, const Locale('en'), 'not-a-map');
    await tester.pumpAndSettle();
    expect(find.text('none'), findsOneWidget);
  });

  testWidgets('check-in sheet: one tap answers and closes', (tester) async {
    CheckInReply? got;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppShell(
        builder: (c, d) => CheckInSheet(
          date: _today,
          tier: 2,
          onReply: (r) async {
            got = r;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('How are you feeling?'), findsOneWidget);
    expect(find.text('I feel fine'), findsOneWidget);
    expect(find.text('A bit run down'), findsOneWidget);
    expect(find.text('Sick / symptoms'), findsOneWidget);
    await tester.tap(find.text('I feel fine'));
    await tester.pumpAndSettle();
    expect(got, CheckInReply.fine);
  });

  group('check-in notification copy localized at the OS boundary', () {
    AppLocalizations l(String code) => lookupAppLocalizations(Locale(code));

    final tier2Body =
        'Your values have deviated from your baseline for the last 3 nights. Do you feel unusually tired or run down?';
    final tier3Body =
        'Across skin temperature, breathing rate and resting heart rate, your values have been above your usual for the last 3 nights. Consider rest, and if this persists, consider checking with a healthcare professional.';

    test('interpolated bodies parse back per locale', () {
      for (final code in ['de', 'es', 'fr', 'hi', 'ru', 'th', 'zh']) {
        final loc = l(code);
        expect(localizedNotificationText(loc, tier2Body), loc.notifCheckInBody(3),
            reason: code);
        expect(localizedNotificationText(loc, tier3Body),
            loc.notifCheckInBodyTier3(3),
            reason: code);
        expect(localizedText(loc, 'Off your usual lately'),
            loc.notifCheckInTitleTier2,
            reason: code);
        expect(localizedText(loc, 'Values above your usual for several nights'),
            loc.notifCheckInTitleTier3,
            reason: code);
      }
    });

    test('english passes through untouched', () {
      final en = l('en');
      expect(localizedNotificationText(en, tier2Body), tier2Body);
      expect(localizedText(en, 'Off your usual lately'), 'Off your usual lately');
    });

    test("the notice's own copy feeds the same mapping", () {
      final notice = CheckInNotice(
          date: '2024-02-10', tier: 2, streak: 3, signals: const ['rhr']);
      final de = l('de');
      expect(localizedNotificationText(de, notice.body), de.notifCheckInBody(3));
      expect(localizedText(de, notice.title), de.notifCheckInTitleTier2);
    });
  });
}
