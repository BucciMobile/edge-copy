// DASHBOARD VO₂max trend — the aggregation that feeds the Health → Trends
// card and the MetricDetail drill-down:
//   • one MEDIAN point per local day that has qualifying history estimates
//   • ONE method only (mixing rule enforced in the DB layer, not the caller)
//   • formula-version boundaries surface as algo_breaks in getChart
//   • the per-session LIVE estimate never charts here — separate claim
//   • empty history = an empty series, never a 0 or a fabricated point
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/vo2max_activity_gate.dart';
import 'package:openstrap_edge/compute/vo2max_history.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  // ISOLATION: fresh DB per test — the old shared-sequence shape made the
  // global `trend` length assertions depend on test ORDER (each test only
  // added its own points and asserted on the WHOLE series).
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_vo2max_trend_test.db';
  });

  setUp(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Future<void> putSessionRow(String id, String type, int startTs) async {
    await LocalDb.putSession({
      'id': id,
      'start_ts': startTs,
      'end_ts': startTs + 1200,
      'type': type,
      'status': 'done',
      'duration_min': 20,
      'source': 'manual',
      'device_family': 'gen4',
      'created_at': startTs * 1000,
    });
  }

  test('split estimates on one day collapse to one median point', () async {
    // Two sessions on the SAME calendar day, splits 52 and 54 → day median 53.
    final day = DateTime(2024, 5, 10, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow('t-a', 'run', day);
    await putSessionRow('t-b', 'run', day + 3600);
    await LocalDb.putVo2maxHistory('t-a', [
      {
        'km': 1,
        'activity_ts': day,
        'vo2max': 52.0,
        'absence_reason': null,
        'method': kVo2maxHistoryMethod,
        'formula_version': kVo2maxHistoryFormulaVersion,
        'hr_max_bpm': 187.0,
        'resting_hr_bpm': 55.0,
        'computed_at': day + 100,
      },
    ]);
    await LocalDb.putVo2maxHistory('t-b', [
      {
        'km': 1,
        'activity_ts': day + 3600,
        'vo2max': 54.0,
        'absence_reason': null,
        'method': kVo2maxHistoryMethod,
        'formula_version': kVo2maxHistoryFormulaVersion,
        'hr_max_bpm': 187.0,
        'resting_hr_bpm': 55.0,
        'computed_at': day + 100,
      },
    ]);
    final trend = await LocalDb.vo2maxHistoryDailyTrend();
    expect(trend, hasLength(1));
    expect((trend.first['v'] as num).toDouble(), 53.0);
  });

  test('days bucket on the LOCAL calendar day, not day-of-month', () async {
    // May 10 and June 10 share a day-of-month (10) but are different days.
    final may = DateTime(2024, 5, 10, 8).millisecondsSinceEpoch ~/ 1000;
    final jun = DateTime(2024, 6, 10, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow('t-may', 'run', may);
    await putSessionRow('t-jun', 'run', jun);
    for (final e in [('t-may', may, 50.0), ('t-jun', jun, 55.0)]) {
      await LocalDb.putVo2maxHistory(e.$1, [
        {
          'km': 1,
          'activity_ts': e.$2,
          'vo2max': e.$3,
          'absence_reason': null,
          'method': kVo2maxHistoryMethod,
          'formula_version': kVo2maxHistoryFormulaVersion,
          'hr_max_bpm': 187.0,
          'resting_hr_bpm': 55.0,
          'computed_at': e.$2 + 100,
        },
      ]);
    }
    final trend = await LocalDb.vo2maxHistoryDailyTrend();
    expect(trend, hasLength(2));
  });

  test('a DIFFERENT method never leaks into the trend (mixing rule)', () async {
    final day = DateTime(2024, 5, 11, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow('t-mix', 'run', day);
    await LocalDb.putVo2maxHistory('t-mix', [
      {
        'km': 1,
        'activity_ts': day,
        'vo2max': 52.0,
        'absence_reason': null,
        'method': kVo2maxHistoryMethod,
        'formula_version': kVo2maxHistoryFormulaVersion,
        'hr_max_bpm': 187.0,
        'resting_hr_bpm': 55.0,
        'computed_at': day + 100,
      },
      {
        'km': 2,
        'activity_ts': day,
        'vo2max': 70.0,
        'absence_reason': null,
        // A foreign "method" — e.g. a device estimate imported alongside.
        // It is a different claim and must not be averaged into this trend.
        'method': 'vendor_device_estimate',
        'formula_version': '1',
        'hr_max_bpm': 187.0,
        'resting_hr_bpm': 55.0,
        'computed_at': day + 100,
      },
    ]);
    final trend = await LocalDb.vo2maxHistoryDailyTrend();
    // The suite shares one DB (like the history suite), so filter to THIS
    // test's day — the foreign-method row must have contributed nothing to
    // IT, i.e. the day's point is the 52 median of the one eligible row.
    final mine = [
      for (final t in trend)
        if ((t['t'] as num).toInt() == day) t,
    ];
    expect(mine, hasLength(1));
    expect((mine.first['v'] as num).toDouble(), 52.0);
  });

  // A day's median must never mix formula versions: 40 produced by v1 and
  // 60 by v2 on the same day medianed to a fabricated 50 that neither chain
  // ever produced, carrying ONE version label as if it were unambiguous.
  // The fix buckets by version WITHIN a day: the day's last version's rows
  // form the day's point, the earlier rows keep their own point.
  test('a day with MIXED formula versions never medians across them', () async {
    final day = DateTime(2024, 5, 13, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow('t-ver1', 'run', day);
    await putSessionRow('t-ver2', 'run', day + 60);
    await LocalDb.putVo2maxHistory('t-ver1', [
      {
        'km': 1,
        'activity_ts': day,
        'vo2max': 40.0,
        'absence_reason': null,
        'method': kVo2maxHistoryMethod,
        'formula_version': '1',
        'hr_max_bpm': 187.0,
        'resting_hr_bpm': 55.0,
        'computed_at': day + 100,
      },
    ]);
    await LocalDb.putVo2maxHistory('t-ver2', [
      {
        'km': 1,
        'activity_ts': day + 60,
        'vo2max': 60.0,
        'absence_reason': null,
        'method': kVo2maxHistoryMethod,
        'formula_version': '2',
        'hr_max_bpm': 187.0,
        'resting_hr_bpm': 55.0,
        'computed_at': day + 100,
      },
    ]);
    final trend = await LocalDb.vo2maxHistoryDailyTrend();
    final mine = [
      for (final t in trend)
        if ((t['t'] as num).toInt() == day ||
            (t['t'] as num).toInt() == day + 60)
          t,
    ];
    // Two SEPARATE points, one per version — never a single mixed 50.
    expect(mine, hasLength(2));
    expect(
      mine.map((p) => (p['v'] as num).toDouble()),
      containsAll(<double>[40.0, 60.0]),
    );
    for (final p in mine) {
      expect(p['v'] as num, anyOf(40.0, 60.0));
    }
  });

  test('an abstention row contributes nothing — never a 0 point', () async {
    final day = DateTime(2024, 5, 12, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow('t-abs', 'walk', day);
    await LocalDb.putVo2maxHistory('t-abs', [
      {
        'km': 1,
        'activity_ts': day,
        'vo2max': null,
        'absence_reason': 'no_qualifying_bout',
        'method': kVo2maxHistoryMethod,
        'formula_version': kVo2maxHistoryFormulaVersion,
        'hr_max_bpm': 187.0,
        'resting_hr_bpm': 55.0,
        'computed_at': day + 100,
      },
    ]);
    final trend = await LocalDb.vo2maxHistoryDailyTrend();
    final mine = [
      for (final t in trend)
        if ((t['t'] as num).toInt() == day) t,
    ];
    expect(mine, isEmpty);
    // And across the whole shared-DB series: no fabricated zero point.
    for (final t in trend) {
      final v = (t['v'] as num?)?.toDouble();
      expect(
        v == null || !v.isFinite || v <= 0.0,
        isFalse,
        reason: 'abstentions must not chart as 0: $t',
      );
    }
  });
  // ── Fix-4 regression: the session median honours method + version ────────
  // vo2maxHistoryMedians used to median over EVERY valued row of a session —
  // a vendor-method row (or an older formula version's) blended into the
  // workout detail's "retrospective estimate" number.
  test(
    'vo2maxHistoryMedians excludes foreign methods and old versions',
    () async {
      const id = 't-med-filter';
      final day = DateTime(2024, 5, 14, 8).millisecondsSinceEpoch ~/ 1000;
      await putSessionRow(id, 'run', day);
      await LocalDb.putVo2maxHistory(id, [
        {
          'km': 1,
          'activity_ts': day,
          'vo2max': 52.0,
          'absence_reason': null,
          'method': kVo2maxHistoryMethod,
          'formula_version': kVo2maxHistoryFormulaVersion,
          'hr_max_bpm': 187.0,
          'resting_hr_bpm': 55.0,
          'computed_at': day + 100,
        },
        {
          'km': 2,
          'activity_ts': day,
          'vo2max': 70.0, // a foreign vendor estimate on the same session
          'absence_reason': null,
          'method': 'vendor_device_estimate',
          'formula_version': '1',
          'hr_max_bpm': 187.0,
          'resting_hr_bpm': 55.0,
          'computed_at': day + 100,
        },
        {
          'km': 3,
          'activity_ts': day,
          'vo2max': 40.0, // the same chain, an older formula version
          'absence_reason': null,
          'method': kVo2maxHistoryMethod,
          'formula_version': '1',
          'hr_max_bpm': 187.0,
          'resting_hr_bpm': 55.0,
          'computed_at': day + 100,
        },
      ]);
      // Unfiltered (legacy behaviour) would median 52/70/40 -> 52 and look
      // innocent; the comparable read must see ONLY the current chain's row.
      final medians = await LocalDb.vo2maxHistoryMedians(
        method: kVo2maxHistoryMethod,
        formulaVersion: kVo2maxHistoryFormulaVersion,
      );
      expect(
        medians[id],
        52.0,
        reason: 'the workout detail must not blend 52/70/40 into one number',
      );

      // And the single-session helper agrees with the filtered map.
      final one = await LocalDb.vo2maxHistoryMedianForSession(
        id,
        method: kVo2maxHistoryMethod,
        formulaVersion: kVo2maxHistoryFormulaVersion,
      );
      expect(one, 52.0);
    },
  );

  // ── Fix-6 unit pins: the grey-zone gate itself ──────────────────────────
  test('acsmSpeedDomainReason: below, inside, above the grey zone', () {
    // Walking-domain pace (1.39 m/s): no reason.
    expect(acsmSpeedDomainReason(1000 / 720), isNull);
    // Comfortable run (3.03 m/s): no reason.
    expect(acsmSpeedDomainReason(1000 / 330), isNull);
    // The boundary itself and its neighbourhood: ambiguous.
    expect(acsmSpeedDomainReason(2.0), 'equation_domain_ambiguous');
    expect(acsmSpeedDomainReason(1.95), 'equation_domain_ambiguous');
    expect(acsmSpeedDomainReason(2.05), 'equation_domain_ambiguous');
    // Just outside the zone on both sides: fine again.
    expect(acsmSpeedDomainReason(1.85), isNull);
    expect(acsmSpeedDomainReason(2.2), isNull);
    // Invalid speeds map to the malformed-row code, not a domain claim.
    expect(acsmSpeedDomainReason(double.nan), 'no_completed_km_split');
    expect(acsmSpeedDomainReason(0), 'no_completed_km_split');
    expect(acsmSpeedDomainReason(-3), 'no_completed_km_split');
  });
}
