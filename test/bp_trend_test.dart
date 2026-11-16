// The imported blood-pressure trend (lib/health/bp_trend.dart): pairing the
// two halves of a cuff reading, the 30/90-day medians, the quality gates and
// the wording discipline. Pure-function tests — no database, no health store.
//
// The hard rule under test: TREND DISPLAY ONLY. No classification of the
// user, ever — the last group scans the user-facing copy for the banned claim
// words, the same way tier_engine_test.dart does for the illness tiers.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/health/bp_trend.dart';
import 'package:openstrap_edge/health/health_measurement_import.dart';

Map<String, dynamic> _sys(String uuid, int ts, double v, {String source = 'Omron'}) =>
    {'uuid': uuid, 'ts': ts, 'kind': kKindSystolic, 'value': v, 'unit': 'mmHg', 'source': source};

Map<String, dynamic> _dia(String uuid, int ts, double v, {String source = 'Omron'}) =>
    {'uuid': uuid, 'ts': ts, 'kind': kKindDiastolic, 'value': v, 'unit': 'mmHg', 'source': source};

/// Health Connect shape: one record, the diastolic half stored under
/// `'<uuid>:bp_diastolic'`.
Map<String, dynamic> _hcDia(String uuid, int ts, double v) =>
    _dia('$uuid:$kKindDiastolic', ts, v);

const int _day = 86400;
// 2024-03-10 12:00:00 UTC.
const int _now = 1710072000;

void main() {
  group('pairBpReadings', () {
    test('pairs halves sharing a record uuid (Health Connect)', () {
      final pairs = pairBpReadings(
        systolic: [_sys('rec1', _now - 100, 128)],
        diastolic: [_hcDia('rec1', _now - 100, 82)],
      );
      expect(pairs, hasLength(1));
      expect(pairs.single.systolic, 128);
      expect(pairs.single.diastolic, 82);
      expect(pairs.single.tsSec, _now - 100);
      expect(pairs.single.source, 'Omron');
    });

    test('pairs separate uuids by timestamp within tolerance (HealthKit)', () {
      final pairs = pairBpReadings(
        systolic: [_sys('s1', _now - 3 * _day, 130, source: 'Apple Health')],
        diastolic: [_dia('d1', _now - 3 * _day + 120, 85, source: 'Apple Health')],
      );
      expect(pairs, hasLength(1));
      expect(pairs.single.source, 'Apple Health');
    });

    test('does not pair halves further apart than the tolerance', () {
      final pairs = pairBpReadings(
        systolic: [_sys('s1', _now, 130)],
        diastolic: [_dia('d1', _now + kBpPairToleranceSec + 1, 85)],
      );
      expect(pairs, isEmpty);
    });

    test('each row is used in at most one pair', () {
      final pairs = pairBpReadings(
        systolic: [_sys('s1', _now, 130), _sys('s2', _now + 10, 131)],
        diastolic: [_dia('d1', _now + 5, 85)],
      );
      expect(pairs, hasLength(1));
    });

    test('a reading with systolic <= diastolic is a bad record and is dropped', () {
      final pairs = pairBpReadings(
        systolic: [_sys('s1', _now, 80)],
        diastolic: [_hcDia('s1', _now, 90)],
      );
      expect(pairs, isEmpty);
    });

    test('out-of-bounds rows are dropped even if the importer let one through', () {
      final pairs = pairBpReadings(
        systolic: [_sys('s1', _now, 400)],
        diastolic: [_hcDia('s1', _now, 85)],
      );
      expect(pairs, isEmpty);
    });

    test('result is sorted oldest first', () {
      final pairs = pairBpReadings(
        systolic: [_sys('b', _now - 2 * _day, 122), _sys('a', _now - 5 * _day, 120)],
        diastolic: [_hcDia('b', _now - 2 * _day, 78), _hcDia('a', _now - 5 * _day, 76)],
      );
      expect([for (final p in pairs) p.tsSec], [_now - 5 * _day, _now - 2 * _day]);
    });
  });

  group('bpWindowTrend', () {
    List<BpReading> mk(int ts, double s, double d) =>
        [BpReading(tsSec: ts, systolic: s, diastolic: d, source: 'Cuff')];

    test('window boundaries are inclusive', () {
      final pairs = [
        ...mk(_now - 30 * _day, 120, 80),
        ...mk(_now - 15 * _day, 122, 81),
        ...mk(_now, 124, 82),
      ];
      final w = bpWindowTrend(pairs, nowSec: _now, windowDays: 30);
      expect(w, isNotNull);
      expect(w!.n, 3);
    });

    test('readings older than the window are excluded', () {
      final pairs = [
        ...mk(_now - 31 * _day, 200, 120), // outside 30d
        ...mk(_now - 10 * _day, 120, 80),
        ...mk(_now - 5 * _day, 122, 81),
        ...mk(_now, 124, 82),
      ];
      final w = bpWindowTrend(pairs, nowSec: _now, windowDays: 30);
      expect(w, isNotNull);
      expect(w!.n, 3);
      expect(w.medianSystolic, 122);
      expect(w.medianDiastolic, 81);
      // But inside 90d.
      final w90 = bpWindowTrend(pairs, nowSec: _now, windowDays: 90);
      expect(w90!.n, 4);
      expect(w90.medianSystolic, 123); // median of 120,122,124,200
    });

    test('fewer than 3 pairs means null, never a median of one', () {
      final pairs = [
        ...mk(_now - 2 * _day, 120, 80),
        ...mk(_now, 122, 81),
      ];
      expect(bpWindowTrend(pairs, nowSec: _now, windowDays: 30), isNull);
      expect(bpWindowTrend(const [], nowSec: _now, windowDays: 30), isNull);
    });

    test('median of an even count averages the two middle values', () {
      final pairs = [
        ...mk(_now - 3 * _day, 110, 70),
        ...mk(_now - 2 * _day, 120, 80),
        ...mk(_now - 1 * _day, 130, 90),
        ...mk(_now, 140, 100),
      ];
      final w = bpWindowTrend(pairs, nowSec: _now, windowDays: 30);
      expect(w!.medianSystolic, 125);
      expect(w.medianDiastolic, 85);
    });

    test('prefers a same-time-of-day bucket when it holds enough readings', () {
      // Three morning readings (08:00) and two evening ones (20:00).
      int atHour(int daysAgo, int hour) {
        final d = DateTime.fromMillisecondsSinceEpoch((_now - daysAgo * _day) * 1000);
        return DateTime(d.year, d.month, d.day, hour, 0).millisecondsSinceEpoch ~/ 1000;
      }
      final pairs = [
        ...mk(atHour(10, 8), 120, 80),
        ...mk(atHour(5, 8), 122, 81),
        ...mk(atHour(1, 8), 124, 82),
        ...mk(atHour(3, 20), 150, 95),
        ...mk(atHour(2, 20), 152, 96),
      ];
      final w = bpWindowTrend(pairs, nowSec: _now, windowDays: 30);
      expect(w, isNotNull);
      expect(w!.sameTimeOfDay, isTrue);
      expect(w.n, 3);
      expect(w.medianSystolic, 122);
      expect(w.medianDiastolic, 81);
    });

    test('falls back to all readings when no time-of-day bucket reaches the gate', () {
      int atHour(int daysAgo, int hour) {
        final d = DateTime.fromMillisecondsSinceEpoch((_now - daysAgo * _day) * 1000);
        return DateTime(d.year, d.month, d.day, hour, 0).millisecondsSinceEpoch ~/ 1000;
      }
      final pairs = [
        ...mk(atHour(9, 6), 120, 80),
        ...mk(atHour(6, 12), 122, 81),
        ...mk(atHour(3, 18), 124, 82),
      ];
      final w = bpWindowTrend(pairs, nowSec: _now, windowDays: 30);
      expect(w, isNotNull);
      expect(w!.sameTimeOfDay, isFalse);
      expect(w.n, 3);
      expect(w.medianSystolic, 122);
    });
  });

  group('summarizeBp', () {
    test('latest is the newest paired reading; windows stay null below the gate', () {
      final s = summarizeBp(
        systolic: [_sys('a', _now - 40 * _day, 118), _sys('b', _now - 2 * _day, 126)],
        diastolic: [_hcDia('a', _now - 40 * _day, 76), _hcDia('b', _now - 2 * _day, 84)],
        nowSec: _now,
      );
      expect(s.readings, hasLength(2));
      expect(s.latest, isNotNull);
      expect(s.latest!.systolic, 126);
      expect(s.d30, isNull); // only 1 pair in 30d
      expect(s.d90, isNull); // only 2 pairs in 90d — the gate is 3, so no median
    });

    test('three pairs in 30d unlock d30 but not a fabricated d90', () {
      final s = summarizeBp(
        systolic: [
          _sys('a', _now - 80 * _day, 110),
          _sys('b', _now - 20 * _day, 120),
          _sys('c', _now - 10 * _day, 130),
          _sys('d', _now - 1 * _day, 140),
        ],
        diastolic: [
          _hcDia('a', _now - 80 * _day, 70),
          _hcDia('b', _now - 20 * _day, 80),
          _hcDia('c', _now - 10 * _day, 90),
          _hcDia('d', _now - 1 * _day, 100),
        ],
        nowSec: _now,
      );
      expect(s.d30, isNotNull);
      expect(s.d30!.n, 3);
      expect(s.d30!.medianSystolic, 130);
      expect(s.d90, isNotNull);
      expect(s.d90!.n, 4);
      expect(s.d90!.medianSystolic, 125);
      expect(s.latest!.diastolic, 100);
    });
  });

  group('wording discipline', () {
    final banned = RegExp(
        r'\b(hypertension|prehypertension|high blood pressure|low blood pressure|'
        r'stage [123]|diagnos\w+|hypotension|you (are|have) (high|ill|sick))\b',
        caseSensitive: false);

    Map<String, String> messagesOf(String path) {
      final raw = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      return {
        for (final e in raw.entries)
          if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String,
      };
    }

    test('bp card copy contains no classification or diagnosis wording', () {
      final en = messagesOf('lib/l10n/app_en.arb');
      final hits = [
        for (final e in en.entries)
          if (e.key.startsWith('bpCard') && banned.hasMatch(e.value)) e.key,
      ];
      expect(hits, isEmpty);
    });

    test('the card file frames guidelines as reference ranges and points to a professional', () {
      final src = File('lib/ui2/screens/bp_card.dart').readAsStringSync();
      expect(src.contains('bpCardReferenceRanges'), isTrue);
      expect(src.contains('bpCardReferenceNote'), isTrue);
      expect(banned.hasMatch(src), isFalse);
    });

    test('every locale keeps the declared placeholders', () {
      final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      for (final key in en.keys.where((k) => k.startsWith('bpCard') && !k.startsWith('@'))) {
        final meta = en['@$key'] as Map<String, dynamic>?;
        final phs = (meta?['placeholders'] as Map<String, dynamic>?)?.keys ?? <String>[];
        for (final loc in ['de', 'es', 'fr', 'hi', 'ru', 'th', 'zh']) {
          final d = jsonDecode(File('lib/l10n/app_$loc.arb').readAsStringSync())
              as Map<String, dynamic>;
          final v = d[key] as String;
          for (final ph in phs) {
            expect(RegExp('\\{$ph(\\}|, )').hasMatch(v), isTrue,
                reason: '$loc $key must keep {$ph}');
          }
        }
      }
    });
  });
}
