// The imported blood-pressure trend card (bpTrendSection in
// lib/ui2/screens/bp_card.dart): shows latest + 30/90-day medians beside the
// guideline reference ranges, says "not enough readings yet" below the pair
// gate instead of a median, and renders translated in every locale. Trend
// display only — the wording-discipline scan lives in bp_trend_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/health/bp_trend.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/bp_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

BpTrendSummary _summary({int n30 = 4, bool with90 = true, int latestSys = 126, int latestDia = 84}) {
  final now = DateTime(2024, 3, 10, 12).millisecondsSinceEpoch ~/ 1000;
  final readings = [
    for (var i = 0; i < n30; i++)
      BpReading(
        tsSec: now - (i + 1) * 86400,
        systolic: (i == n30 - 1 ? latestSys : 120 + i).toDouble(),
        diastolic: (i == n30 - 1 ? latestDia : 78 + i).toDouble(),
        source: 'Omron Connect',
      ),
  ];
  return BpTrendSummary(
    readings: readings,
    d30: n30 >= kMinBpPairsPerWindow
        ? BpWindow(
            n: n30,
            medianSystolic: 121.5,
            medianDiastolic: 79.5,
            sameTimeOfDay: true,
            firstTsSec: readings.last.tsSec,
            lastTsSec: readings.first.tsSec,
          )
        : null,
    d90: with90 && n30 >= kMinBpPairsPerWindow
        ? BpWindow(
            n: n30 + 2,
            medianSystolic: 120.0,
            medianDiastolic: 78.0,
            sameTimeOfDay: false,
            firstTsSec: readings.last.tsSec,
            lastTsSec: now,
          )
        : null,
  );
}

Future<void> _pump(WidgetTester tester, Locale locale, BpTrendSummary s) =>
    tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppShell(
        builder: (c, d) => Scaffold(
          body: ListView(children: [bpTrendSection(c, s)]),
        ),
      ),
    ));

void main() {
  testWidgets('shows latest, 30/90-day medians and the reference ranges', (tester) async {
    await _pump(tester, const Locale('en'), _summary());
    await tester.pumpAndSettle();
    expect(find.textContaining('Blood pressure from'), findsOneWidget);
    expect(find.text('Latest reading'), findsOneWidget);
    expect(find.text('126/84'), findsOneWidget);
    expect(find.text('Median, last 30 days'), findsOneWidget);
    expect(find.text('122/80'), findsOneWidget); // 121.5/79.5 rounded
    expect(find.text('Median, last 90 days'), findsOneWidget);
    expect(find.textContaining('Guideline reference ranges'), findsOneWidget);
    expect(find.textContaining('130/80'), findsOneWidget);
    expect(find.textContaining('140/90'), findsOneWidget);
    expect(find.textContaining('healthcare professional'), findsOneWidget);
    expect(find.textContaining('taken at a similar time of day'), findsOneWidget);
  });

  testWidgets('below the pair gate: latest reading plus honest quiet state, no median', (tester) async {
    await _pump(tester, const Locale('en'), _summary(n30: 2, with90: false));
    await tester.pumpAndSettle();
    expect(find.text('Latest reading'), findsOneWidget);
    expect(find.text('Not enough readings for a trend yet'), findsOneWidget);
    expect(find.textContaining('2 are in so far'), findsOneWidget);
    expect(find.textContaining('Median'), findsNothing);
    // The reference framing is still there — the card is not a verdict.
    expect(find.textContaining('healthcare professional'), findsOneWidget);
  });

  testWidgets('a German user gets the German card', (tester) async {
    await _pump(tester, const Locale('de'), _summary());
    await tester.pumpAndSettle();
    expect(find.textContaining('Blutdruck von'), findsOneWidget);
    expect(find.text('Letzte Messung'), findsOneWidget);
    expect(find.text('Median der letzten 30 Tage'), findsOneWidget);
    expect(find.textContaining('Blutdruck von'), findsOneWidget);
    expect(find.text('Median, last 30 days'), findsNothing);
  });

  test('every locale has the bp card keys, translated', () {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final loc in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(loc);
      expect(l.bpCardTitle('X'), isNotEmpty, reason: '$loc');
      expect(l.bpCardLatest, isNotEmpty, reason: '$loc');
      expect(l.bpCardMedian30, isNotEmpty, reason: '$loc');
      expect(l.bpCardMedian90, isNotEmpty, reason: '$loc');
      expect(l.bpCardReadingsCount(5), isNotEmpty, reason: '$loc');
      expect(l.bpCardReadingsCount(1), isNotEmpty, reason: '$loc');
      expect(l.bpCardSameTimeOfDay, isNotEmpty, reason: '$loc');
      expect(l.bpCardNotEnoughTitle, isNotEmpty, reason: '$loc');
      expect(l.bpCardNotEnoughBody(2), isNotEmpty, reason: '$loc');
      expect(l.bpCardReferenceRanges, isNotEmpty, reason: '$loc');
      expect(l.bpCardReferenceNote, isNotEmpty, reason: '$loc');
      if (loc.languageCode != 'en') {
        expect(l.bpCardTitle('X'), isNot(en.bpCardTitle('X')),
            reason: '$loc should be translated');
        expect(l.bpCardReferenceNote, isNot(en.bpCardReferenceNote),
            reason: '$loc should be translated');
      }
    }
  });

  test('the reference-range copy names the guideline ranges, never a classification', () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect(en.bpCardReferenceRanges, contains('130/80'));
    expect(en.bpCardReferenceRanges, contains('140/90'));
    expect(en.bpCardReferenceRanges, contains('ACC/AHA'));
    expect(en.bpCardReferenceRanges, contains('ESC'));
    final banned = RegExp(
        r'\b(hypertension|prehypertension|high blood pressure|diagnos\w*)\b',
        caseSensitive: false);
    for (final loc in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(loc);
      expect(banned.hasMatch(l.bpCardReferenceRanges), isFalse, reason: '$loc');
      expect(banned.hasMatch(l.bpCardReferenceNote), isFalse, reason: '$loc');
      expect(banned.hasMatch(l.bpCardTitle('X')), isFalse, reason: '$loc');
    }
  });
}
