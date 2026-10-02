// RETROSPECTIVE VO₂max history pass (`lib/compute/vo2max_history.dart`)
// over a REAL LocalDb (sqflite_ffi):
//   • a stored km split with steady HR and valid anchors → a history row.
//   • the session's own row (vo2max_estimate, routes) stays UNTOUCHED.
//   • casual-stroll HR (below the 40 %HRR floor) abstains with a code.
//   • a cycling split abstains as unsupported_activity.
//   • a session with no pre-session RHR (and no manual) abstains — never
//     a population default.
//   • re-running the pass (force) replaces rows in place, no duplicates.
//   • the live estimate and the history estimate are computed independently
//     and both survive together on one session.
//   • the session's own peak HR is never the HRmax anchor: a session whose
//     stored max exceeds the age line still grades against the AGE line (or
//     an earlier observed ceiling), not against itself.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/vo2max_history.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_vo2max_history_test.db';
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

  test('a stored km split with anchors becomes a history estimate', () async {
    const id = 'h-run-1';
    // 2024-05-10, a real calendar day, so the RHR seed below (2024-05-09)
    // is strictly before it.
    final startTs =
        DateTime(2024, 5, 10, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    final res = await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
    );
    expect(res.estimated, 1);

    final rows = await LocalDb.vo2maxHistory();
    expect(rows, hasLength(1));
    final r = rows.first;
    expect(r['session_id'], id);
    expect(r['vo2max'], isNotNull);
    // Same reference case as the method test: 3.0303 m/s at %HRR ~0.72 →
    // ~54 ml/kg/min (age 30 → HRmax 187, RHR 55).
    expect((r['vo2max'] as num).toDouble(), closeTo(54.0, 0.5));
    expect(r['method'], kVo2maxHistoryMethod);
    expect(r['formula_version'], kVo2maxHistoryFormulaVersion);
    expect(r['activity_ts'], startTs);
    expect(r['computed_at'], greaterThan(0));

    // The session's own columns stay UNTOUCHED — this pass never writes to
    // `sessions` (the live estimate stays null: nothing set it here).
    final sess = await LocalDb.session(id);
    expect(sess?['vo2max_estimate'], isNull);
    expect(sess?['vo2max_method'], isNull);
  });

  // The stored table DOES carry the partial trailing km (computeSplits emits
  // it), and its distance is whatever remained — not 1000 m. Its "speed" is
  // not a real pace over a fixed distance, so the ACSM equation must never
  // see it — same >= 999 m rule as the live pass.
  test('a PARTIAL trailing km split abstains as no_completed_km_split',
      () async {
    const id = 'h-partial-1';
    final startTs =
        DateTime(2024, 5, 10, 11).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    // 400 m in 130 s — pace-wise indistinguishable from the qualifying
    // fixture (same speed, HR inside the band), only the DISTANCE is short.
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 400.0, 'duration_sec': 130, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);
    await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
      force: true,
    );
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).toList();
    expect(mine, hasLength(1));
    expect(mine.first['vo2max'], isNull,
        reason: 'a partial km has no fixed distance; feeding its "speed" '
            'to ACSM would fabricate a pace the data does not have');
    expect(mine.first['absence_reason'], 'no_completed_km_split');
  });

  test('a casual stroll abstains (below the %HRR floor), with a code',
      () async {
    const id = 'h-walk-1';
    final startTs =
        DateTime(2024, 5, 10, 10).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'walk', startTs);
    // 1 km in 720 s (a stroll), HR 60 — barely above RHR: %HRR ~4%.
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 720, 'avg_hr': 60.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
      force: true,
    );
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).toList();
    expect(mine, hasLength(1));
    expect(mine.first['vo2max'], isNull);
    // The analytics floor fired: no steady submaximal bout, not a zero.
    expect(mine.first['absence_reason'], 'no_qualifying_bout');
  });

  test('a cycling split abstains as unsupported_activity', () async {
    const id = 'h-bike-1';
    final startTs =
        DateTime(2024, 5, 10, 12).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'cycle', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 120, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
      force: true,
    );
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).toList();
    expect(mine.first['absence_reason'], 'unsupported_activity');
    expect(mine.first['vo2max'], isNull);
  });

  test('no pre-session RHR and no manual value abstains — no default',
      () async {
    const id = 'h-norhr-1';
    // Before ANY seeded rhr date (May 9): nothing is historically available.
    final startTs =
        DateTime(2024, 3, 1, 14).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    // NO rhr series value before this session; profile has no manual RHR.

    await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
      force: true,
    );
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).toList();
    expect(mine.first['absence_reason'], 'no_resting_hr_available');
    expect(mine.first['vo2max'], isNull);
  });

  test('a LATER rhr value is not used as a historical anchor', () async {
    const id = 'h-later-1';
    // April: the only rhr seed on disk that could apply is dated June —
    // AFTER the session, so not historically available at its date.
    final startTs =
        DateTime(2024, 4, 1, 16).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    // Only a value dated AFTER the session: not historically available.
    await LocalDb.putMetricSeriesValue('2024-06-01', 'rhr', 50.0);
    // And the May 9 seed from the first test is also after April 1.

    await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
      force: true,
    );
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).toList();
    expect(mine.first['absence_reason'], 'no_resting_hr_available');
  });

  test('the session peak HR is never the HRmax anchor', () async {
    const id = 'h-peak-1';
    final startTs =
        DateTime(2024, 5, 10, 18).millisecondsSinceEpoch ~/ 1000;
    // Stored max 205 — a one-off spike. The age line (30 → 187) must win,
    // because a workout peak is a lower bound on HRmax, not HRmax itself.
    await LocalDb.putSession({
      'id': id,
      'start_ts': startTs,
      'end_ts': startTs + 1200,
      'type': 'run',
      'status': 'done',
      'duration_min': 20,
      'max_hr': 205,
      'source': 'manual',
      'device_family': 'gen4',
      'created_at': startTs * 1000,
    });
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
      force: true,
    );
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).first;
    // Graded against 187 (age line), not 205: same ~54 as the reference case.
    expect((mine['hr_max_bpm'] as num).toDouble(), 187.0);
    expect((mine['vo2max'] as num).toDouble(), closeTo(54.0, 0.5));
  });

  test('re-running (force) replaces in place — no duplicates, same values',
      () async {
    const id = 'h-once-1';
    final startTs =
        DateTime(2024, 5, 11, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
      {'km': 2, 'meters': 1000.0, 'duration_sec': 340, 'avg_hr': 152.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    final first = await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
      force: true,
    );
    // Force re-walks EVERY session on disk, so the global counts cover all
    // tests' sessions — the idempotence claim is about THIS session's rows.
    expect(first.estimated, greaterThanOrEqualTo(2));
    var rows = await LocalDb.vo2maxHistory();
    final before = [
      for (final r in rows.where((r) => r['session_id'] == id))
        (r['km'], r['vo2max'])
    ];
    // v2 BOUT semantics: two consecutive usable splits of one session form
    // ONE contiguous bout and are graded TOGETHER — one row at the bout's
    // first km, not one row per km.
    expect(before, hasLength(1));
    expect(before.first.$1, 1);
    expect(before.first.$2, isNotNull);

    final second = await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
      force: true,
    );
    expect(second.estimated, greaterThanOrEqualTo(2));
    rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).toList();
    expect(mine, hasLength(1)); // still exactly one bout row, not two
    // Same values recomputed — idempotent, not accumulated.
    expect((mine[0]['km'], mine[0]['vo2max']), before.first);
  });

  test('the freshness gate short-circuits a second non-forced pass',
      () async {
    const id = 'h-gate-1';
    final startTs =
        DateTime(2024, 5, 12, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    // Forced: bypasses the freshness gate an earlier test already set.
    final first = await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
      force: true,
    );
    expect(first.didWork, isTrue);
    // Not forced: gated by compute_freshness, nothing new happens.
    final second = await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
    );
    expect(second.didWork, isFalse);
  });

  // The pass used to set its freshness flag on the FIRST derive — before
  // any workout existed on a fresh install — and never ran again, so no
  // session finalized after the first derive was ever backfilled and the
  // trend stayed empty forever. INCREMENTAL is the fix: the flag's
  // formula_version only gates the FULL pass; every later derive walks
  // sessions that have splits but no history rows yet.
  test('a session finalized AFTER the first pass is still backfilled',
      () async {
    const id = 'h-incremental-1';
    final startTs =
        DateTime(2024, 5, 13, 8).millisecondsSinceEpoch ~/ 1000;
    // A non-forced pass first: the earlier tests left the freshness flag
    // set, so this would short-circuit under the OLD one-shot gate.
    final gated = await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
    );
    expect(gated.didWork, isFalse); // nothing new on disk yet

    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    // Non-forced: the incremental probe must find the new session anyway.
    final res = await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
    );
    expect(res.didWork, isTrue);
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).toList();
    expect(mine, hasLength(1));
    expect(mine.first['vo2max'], isNotNull);
    expect((mine.first['vo2max'] as num).toDouble(), closeTo(54.0, 0.5));
  });

  test('medians per session are exposed for the display aggregate', () async {
    // h-run-1 has one estimated split; h-once-1 has two; the bike/stroll
    // sessions have none. The median map must contain exactly the sessions
    // with at least one VALUE (abstentions excluded), median over values.
    final medians = await LocalDb.vo2maxHistoryMedians();
    expect(medians.containsKey('h-run-1'), isTrue);
    expect(medians.containsKey('h-once-1'), isTrue);
    expect(medians.containsKey('h-bike-1'), isFalse);
    expect(medians['h-run-1'], closeTo(54.0, 0.5));
  });

  test('session deletion cascades to the history rows', () async {
    await LocalDb.deleteSession('h-run-1');
    final rows = await LocalDb.vo2maxHistory();
    expect(rows.where((r) => r['session_id'] == 'h-run-1'), isEmpty);
  });

  // ── Anker-Qualität ─────────────────────────────────────────────────────
  // A vendor-imported RHR day is another algorithm's output, not this
  // person's measurement. db.dart's own convention (metricSeries,
  // measuredOnly) requires that anything that COMPUTES against the series
  // exclude imported days. The history pass grades real estimates against
  // this anchor, so it must too.
  test('an imported RHR day is not used as a historical anchor', () async {
    const id = 'h-import-1';
    // BEFORE every measured seed on disk (May 9): the only rhr day prior to
    // this session is the imported one, so the fallback cannot rescue it.
    final startTs =
        DateTime(2024, 3, 15, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    // The ONLY rhr before the session is a vendor-imported day: the series
    // row AND its provenance stamp are written together by putDayResult
    // (source non-'band' is exactly what _importedDatesSql reads). If the
    // pass used it, the estimate would silently carry a foreign algorithm's
    // number as this user's anchor.
    await LocalDb.putDayResult(
      dayId: '2024-03-14',
      algoVersion: 1,
      payloadJson: '{}',
      windowJson: '{}',
      source: 'apple-health',
      series: {'rhr': 40.0},
    );

    await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
      force: true,
    );
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).first;
    expect(mine['vo2max'], isNull,
        reason: 'an imported day is not a measured anchor; the pass must '
            'abstain rather than grade against a foreign algorithm\'s RHR');
    expect(mine['absence_reason'], 'no_resting_hr_available');
  });
}
