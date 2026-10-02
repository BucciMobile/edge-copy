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

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/vo2max_history.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  // ISOLATION: every test runs against a FRESH database. The file used to
  // share one DB across the whole sequence, so a test's sessions, RHR seeds
  // and freshness payload leaked into every later test's counts and — worse
  // — several assertions only held because of the ORDER (the medians test
  // read sessions earlier tests had written; the incremental test relied on
  // the freshness gate an earlier test had set). Each test now seeds exactly
  // what IT needs.
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_vo2max_history_test.db';
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

  test('a stored km split with anchors becomes a history estimate', () async {
    const id = 'h-run-1';
    // 2024-05-10, a real calendar day, so the RHR seed below (2024-05-09)
    // is strictly before it.
    final startTs = DateTime(2024, 5, 10, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    final res = await backfillVo2maxHistory(getProfileMap: () => {'age': 30});
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
  test(
    'a PARTIAL trailing km split abstains as no_completed_km_split',
    () async {
      const id = 'h-partial-1';
      final startTs = DateTime(2024, 5, 10, 11).millisecondsSinceEpoch ~/ 1000;
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
      expect(
        mine.first['vo2max'],
        isNull,
        reason:
            'a partial km has no fixed distance; feeding its "speed" '
            'to ACSM would fabricate a pace the data does not have',
      );
      expect(mine.first['absence_reason'], 'no_completed_km_split');
    },
  );

  test(
    'a casual stroll abstains (below the %HRR floor), with a code',
    () async {
      const id = 'h-walk-1';
      final startTs = DateTime(2024, 5, 10, 10).millisecondsSinceEpoch ~/ 1000;
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
    },
  );

  test('a cycling split abstains as unsupported_activity', () async {
    const id = 'h-bike-1';
    final startTs = DateTime(2024, 5, 10, 12).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'cycle', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 120, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    await backfillVo2maxHistory(getProfileMap: () => {'age': 30}, force: true);
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).toList();
    expect(mine.first['absence_reason'], 'unsupported_activity');
    expect(mine.first['vo2max'], isNull);
  });

  test(
    'no pre-session RHR and no manual value abstains — no default',
    () async {
      const id = 'h-norhr-1';
      // Before ANY seeded rhr date (May 9): nothing is historically available.
      final startTs = DateTime(2024, 3, 1, 14).millisecondsSinceEpoch ~/ 1000;
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
    },
  );

  test('a LATER rhr value is not used as a historical anchor', () async {
    const id = 'h-later-1';
    // April: the only rhr seed on disk that could apply is dated June —
    // AFTER the session, so not historically available at its date.
    final startTs = DateTime(2024, 4, 1, 16).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    // Only a value dated AFTER the session: not historically available.
    await LocalDb.putMetricSeriesValue('2024-06-01', 'rhr', 50.0);
    // And the May 9 seed from the first test is also after April 1.

    await backfillVo2maxHistory(getProfileMap: () => {'age': 30}, force: true);
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).toList();
    expect(mine.first['absence_reason'], 'no_resting_hr_available');
  });

  test('the session peak HR is never the HRmax anchor', () async {
    const id = 'h-peak-1';
    final startTs = DateTime(2024, 5, 10, 18).millisecondsSinceEpoch ~/ 1000;
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

    await backfillVo2maxHistory(getProfileMap: () => {'age': 30}, force: true);
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).first;
    // Graded against 187 (age line), not 205: same ~54 as the reference case.
    expect((mine['hr_max_bpm'] as num).toDouble(), 187.0);
    expect((mine['vo2max'] as num).toDouble(), closeTo(54.0, 0.5));
  });

  test(
    're-running (force) replaces in place — no duplicates, same values',
    () async {
      const id = 'h-once-1';
      final startTs = DateTime(2024, 5, 11, 8).millisecondsSinceEpoch ~/ 1000;
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
      // Force re-walks every session on THIS test's fresh DB — just this one.
      // The idempotence claim is about THIS session's rows.
      expect(first.estimated, 1);
      expect(first.abstained, 0);
      var rows = await LocalDb.vo2maxHistory();
      final before = [
        for (final r in rows.where((r) => r['session_id'] == id))
          (r['km'], r['vo2max']),
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
      expect(second.estimated, 1);
      rows = await LocalDb.vo2maxHistory();
      final mine = rows.where((r) => r['session_id'] == id).toList();
      expect(mine, hasLength(1)); // still exactly one bout row, not two
      // Same values recomputed — idempotent, not accumulated.
      expect((mine[0]['km'], mine[0]['vo2max']), before.first);
    },
  );

  test('the freshness gate short-circuits a second non-forced pass', () async {
    const id = 'h-gate-1';
    final startTs = DateTime(2024, 5, 12, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    // Forced: bypasses the freshness gate (none is set on this fresh DB,
    // so force is what a first run after a version bump looks like).
    final first = await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
      force: true,
    );
    expect(first.didWork, isTrue);
    // Not forced: gated by the fingerprints the first pass just stored —
    // unchanged inputs, nothing new happens.
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
  test(
    'a session finalized AFTER the first pass is still backfilled',
    () async {
      const id = 'h-incremental-1';
      final startTs = DateTime(2024, 5, 13, 8).millisecondsSinceEpoch ~/ 1000;
      // A non-forced pass first on an EMPTY database: it runs the full pass
      // (no version payload on disk yet), finds nothing, and stores only
      // the version gate. The point: a pass BEFORE any workout exists must
      // not block later sessions — the old one-shot gate did exactly that.
      final gated = await backfillVo2maxHistory(
        getProfileMap: () => {'age': 30},
      );
      expect(gated.didWork, isFalse); // nothing on disk to walk

      await putSessionRow(id, 'run', startTs);
      await LocalDb.putWorkoutSplits(id, [
        {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
      ]);
      await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

      // Non-forced: the incremental probe must find the new session anyway.
      final res = await backfillVo2maxHistory(getProfileMap: () => {'age': 30});
      expect(res.didWork, isTrue);
      final rows = await LocalDb.vo2maxHistory();
      final mine = rows.where((r) => r['session_id'] == id).toList();
      expect(mine, hasLength(1));
      expect(mine.first['vo2max'], isNotNull);
      expect((mine.first['vo2max'] as num).toDouble(), closeTo(54.0, 0.5));
    },
  );

  // Self-contained (isolation): the old shape read sessions EARLIER tests
  // had written; each test now seeds its own fixture.
  test('medians per session are exposed for the display aggregate', () async {
    const id = 'h-med-1';
    final startTs = DateTime(2024, 5, 10, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
      {'km': 2, 'meters': 1000.0, 'duration_sec': 340, 'avg_hr': 152.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);
    await backfillVo2maxHistory(getProfileMap: () => {'age': 30}, force: true);
    final medians = await LocalDb.vo2maxHistoryMedians();
    expect(medians.containsKey(id), isTrue);
    // Two consecutive splits form ONE bout graded together; the bout's
    // value (52.7) differs from the single-km reference (54) because the
    // second km is slower — the pin is the BOUT value, not the 1-km one.
    expect(medians[id]!, inInclusiveRange(52.0, 53.5));
  });

  test('session deletion cascades to the history rows', () async {
    const id = 'h-del-1';
    final startTs = DateTime(2024, 5, 10, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);
    await backfillVo2maxHistory(getProfileMap: () => {'age': 30}, force: true);
    final before = await LocalDb.vo2maxHistory();
    expect(before.where((r) => r['session_id'] == id), isNotEmpty);
    await LocalDb.deleteSession(id);
    final rows = await LocalDb.vo2maxHistory();
    expect(rows.where((r) => r['session_id'] == id), isEmpty);
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
    final startTs = DateTime(2024, 3, 15, 8).millisecondsSinceEpoch ~/ 1000;
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

    await backfillVo2maxHistory(getProfileMap: () => {'age': 30}, force: true);
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).first;
    expect(
      mine['vo2max'],
      isNull,
      reason:
          'an imported day is not a measured anchor; the pass must '
          'abstain rather than grade against a foreign algorithm\'s RHR',
    );
    expect(mine['absence_reason'], 'no_resting_hr_available');
  });
  // ── Fix-1 regression: bout formation must not discard valid rows ────────
  // The old shape added every well-formed row to the bout and graded the
  // whole list inside vo2maxFromHistoricalBout, whose per-row loop abstained
  // the ENTIRE bout on the first invalid member. A trailing partial km (the
  // common case) therefore threw away every valid km before it.
  test('a partial TRAILING km keeps the valid bout before it', () async {
    const id = 'h-bout-tail';
    final startTs = DateTime(2024, 6, 1, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
      {'km': 2, 'meters': 1000.0, 'duration_sec': 340, 'avg_hr': 152.0},
      // Partial trailing km: same pace-ish, but no fixed distance.
      {'km': 3, 'meters': 400.0, 'duration_sec': 132, 'avg_hr': 151.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    final res = await backfillVo2maxHistory(
      getProfileMap: () => {'age': 30},
      force: true,
    );
    expect(res.didWork, isTrue);
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).toList();
    // One VALUE row for the bout of km 1+2, one ABSTENTION row for km 3 —
    // the valid bout survives, the partial km gets its own reason.
    expect(mine, hasLength(2));
    final valued = mine.where((r) => r['vo2max'] != null).toList();
    expect(valued, hasLength(1));
    expect(valued.first['km'], 1);
    expect((valued.first['vo2max'] as num).toDouble(), greaterThan(0));
    final partial = mine.where((r) => r['vo2max'] == null).toList();
    expect(partial, hasLength(1));
    expect(partial.first['km'], 3);
    expect(partial.first['absence_reason'], 'no_completed_km_split');
  });

  test('a missing-HR split splits the bout, not the session', () async {
    const id = 'h-bout-nohr';
    final startTs = DateTime(2024, 6, 2, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
      {'km': 2, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': null},
      {'km': 3, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    await backfillVo2maxHistory(getProfileMap: () => {'age': 30}, force: true);
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).toList();
    // km 1 is its own bout, km 2 abstains with its OWN reason, km 3 forms
    // a new bout — no joint bout across the invalid row, and no wholesale
    // discard either.
    expect(mine, hasLength(3));
    expect(mine.where((r) => r['vo2max'] != null), hasLength(2));
    final noHr = mine.firstWhere((r) => r['km'] == 2);
    expect(noHr['vo2max'], isNull);
    expect(noHr['absence_reason'], 'no_steady_hr_for_split');
  });

  test('a km GAP (1 -> 3) splits into two bouts, both graded', () async {
    const id = 'h-bout-gap';
    final startTs = DateTime(2024, 6, 3, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
      {'km': 3, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

    await backfillVo2maxHistory(getProfileMap: () => {'age': 30}, force: true);
    final rows = await LocalDb.vo2maxHistory();
    final mine = rows.where((r) => r['session_id'] == id).toList();
    // Two SEPARATE single-km bouts, both with a value — the gap does not
    // poison km 3 with km 2's absence (the old code abstained the whole
    // list via vo2maxFromHistoricalBout's consecutive-km check).
    expect(mine, hasLength(2));
    for (final r in mine) {
      expect(
        r['vo2max'],
        isNotNull,
        reason: 'km ${r['km']} must keep its own estimate',
      );
    }
  });

  // ── Fix-2 regression: changed inputs must re-run, unchanged must not ────
  test(
    'a CORRECTED split re-walks a session the pass already graded',
    () async {
      const id = 'h-fp-change';
      final startTs = DateTime(2024, 6, 5, 8).millisecondsSinceEpoch ~/ 1000;
      await putSessionRow(id, 'run', startTs);
      await LocalDb.putWorkoutSplits(id, [
        {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
      ]);
      await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

      final first = await backfillVo2maxHistory(
        getProfileMap: () => {'age': 30},
        force: true,
      );
      expect(first.didWork, isTrue);
      var rows = await LocalDb.vo2maxHistory();
      final before =
          (rows.firstWhere((r) => r['session_id'] == id)['vo2max'] as num)
              .toDouble();

      // Unchanged inputs: the incremental pass must NOT re-walk (fingerprint
      // unchanged), and must not change any row.
      final second = await backfillVo2maxHistory(
        getProfileMap: () => {'age': 30},
      );
      expect(
        second.didWork,
        isFalse,
        reason: 'unchanged inputs must not trigger a recompute',
      );

      // NOW correct the split (late HR join arrived): a genuinely different
      // input fingerprint must re-walk the session and replace its row.
      await LocalDb.putWorkoutSplits(id, [
        {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 140.0},
      ]);
      final third = await backfillVo2maxHistory(
        getProfileMap: () => {'age': 30},
      );
      expect(
        third.didWork,
        isTrue,
        reason: 'a changed split must trigger a re-walk',
      );
      rows = await LocalDb.vo2maxHistory();
      final mine = rows.where((r) => r['session_id'] == id).toList();
      expect(mine, hasLength(1)); // replaced, not duplicated
      final after = (mine.first['vo2max'] as num).toDouble();
      expect(
        after,
        isNot(before),
        reason: 'the corrected HR must change the estimate',
      );
    },
  );

  test(
    'a LATE-AVAILABLE HR on a previously ungradable split upgrades it',
    () async {
      const id = 'h-fp-latehr';
      final startTs = DateTime(2024, 6, 6, 8).millisecondsSinceEpoch ~/ 1000;
      await putSessionRow(id, 'run', startTs);
      await LocalDb.putWorkoutSplits(id, [
        {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': null},
      ]);
      await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

      await backfillVo2maxHistory(
        getProfileMap: () => {'age': 30},
        force: true,
      );
      var rows = await LocalDb.vo2maxHistory();
      var mine = rows.where((r) => r['session_id'] == id).toList();
      expect(mine.first['vo2max'], isNull);
      expect(mine.first['absence_reason'], 'no_steady_hr_for_split');

      // The 1 Hz join lands later; the next incremental pass must re-grade.
      await LocalDb.putWorkoutSplits(id, [
        {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
      ]);
      await backfillVo2maxHistory(getProfileMap: () => {'age': 30});
      rows = await LocalDb.vo2maxHistory();
      mine = rows.where((r) => r['session_id'] == id).toList();
      expect(mine, hasLength(1));
      expect(
        mine.first['vo2max'],
        isNotNull,
        reason: 'a formerly absent reason must upgrade to a value',
      );
      expect(mine.first['absence_reason'], isNull);
    },
  );

  // ── Fix-6 regression: the walk/run equation grey zone abstains ─────────
  test(
    'a bout at the 2.0 m/s equation boundary abstains (grey zone)',
    () async {
      const id = 'h-greyzone';
      final startTs = DateTime(2024, 6, 7, 8).millisecondsSinceEpoch ~/ 1000;
      await putSessionRow(id, 'run', startTs);
      // 1000 m in 500 s = 2.0 m/s exactly: walking equation says 15.5,
      // running equation 27.5 ml/kg/min submax — a 12-unit jump over a hair
      // of pace. The estimate must ABSTAIN, not pick one.
      await LocalDb.putWorkoutSplits(id, [
        {'km': 1, 'meters': 1000.0, 'duration_sec': 500, 'avg_hr': 150.0},
      ]);
      await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);

      await backfillVo2maxHistory(
        getProfileMap: () => {'age': 30},
        force: true,
      );
      final rows = await LocalDb.vo2maxHistory();
      final mine = rows.where((r) => r['session_id'] == id).toList();
      expect(mine.first['vo2max'], isNull);
      expect(mine.first['absence_reason'], 'equation_domain_ambiguous');
    },
  );

  // ── Fix-7 regression: no orphan rows under a deleted session ────────────
  test('putVo2maxHistory writes NOTHING under a deleted session', () async {
    const id = 'h-orphan';
    await LocalDb.putSession({
      'id': id,
      'start_ts': 1700000000,
      'end_ts': 1700001200,
      'type': 'run',
      'status': 'done',
      'duration_min': 20,
      'source': 'manual',
      'device_family': 'gen4',
      'created_at': 1700000000000,
    });
    await LocalDb.deleteSession(id);
    await LocalDb.putVo2maxHistory(id, [
      {
        'km': 1,
        'activity_ts': 1700000000,
        'vo2max': 54.0,
        'absence_reason': null,
        'method': kVo2maxHistoryMethod,
        'formula_version': kVo2maxHistoryFormulaVersion,
        'hr_max_bpm': 187.0,
        'resting_hr_bpm': 55.0,
        'computed_at': 1700000100000,
      },
    ]);
    final rows = await LocalDb.vo2maxHistory();
    expect(
      rows.where((r) => r['session_id'] == id),
      isEmpty,
      reason: 'a deleted session must not gain history rows',
    );
  });

  // ── Fingerprint PROVENANCE: anchors, not just splits, re-walk ──────────
  // The fingerprint covers the RESOLVED anchors, so anchor-history changes
  // must re-walk a session whose SPLITS never changed.
  test(
    'a LATER-MEASURED historical RHR re-walks the session (splits unchanged)',
    () async {
      const id = 'h-prov-rhr';
      final startTs = DateTime(2024, 6, 10, 8).millisecondsSinceEpoch ~/ 1000;
      await putSessionRow(id, 'run', startTs);
      await LocalDb.putWorkoutSplits(id, [
        {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
      ]);
      // No RHR before the session yet: abstains with the anchor reason.
      await backfillVo2maxHistory(
        getProfileMap: () => {'age': 30},
        force: true,
      );
      var mine = (await LocalDb.vo2maxHistory())
          .where((r) => r['session_id'] == id)
          .toList();
      expect(mine.first['vo2max'], isNull);
      expect(mine.first['absence_reason'], 'no_resting_hr_available');

      // The nightly RHR for the day BEFORE the session arrives later (the band
      // synced overnight). Splits untouched — the fingerprint must still change
      // because the RESOLVED anchor changed.
      await LocalDb.putMetricSeriesValue('2024-06-09', 'rhr', 55.0);
      final res = await backfillVo2maxHistory(getProfileMap: () => {'age': 30});
      expect(
        res.didWork,
        isTrue,
        reason: 'a newly available historical anchor must re-walk',
      );
      mine = (await LocalDb.vo2maxHistory())
          .where((r) => r['session_id'] == id)
          .toList();
      expect(mine, hasLength(1));
      expect(mine.first['vo2max'], isNotNull);
      expect(
        mine.first['absence_reason'],
        isNull,
        reason: 'the former abstention must be fully replaced, reason and all',
      );
    },
  );

  test(
    'a LATER ceiling does not displace the as-of anchor of an OLD session',
    () async {
      const id = 'h-prov-ceiling';
      // May 10 session; a ceiling measured May 11 must NOT grade it.
      final startTs = DateTime(2024, 5, 10, 8).millisecondsSinceEpoch ~/ 1000;
      await putSessionRow(id, 'run', startTs);
      await LocalDb.putWorkoutSplits(id, [
        {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
      ]);
      await LocalDb.putMetricSeriesValue('2024-05-09', 'rhr', 55.0);
      await backfillVo2maxHistory(
        getProfileMap: () => {'age': 30},
        force: true,
      );
      var mine = (await LocalDb.vo2maxHistory())
          .where((r) => r['session_id'] == id)
          .first;
      // Graded against the AGE line (187 at 30), no ceiling existed before.
      expect((mine['hr_max_bpm'] as num).toDouble(), 187.0);

      // A harder workout LATER raises today's ceiling to 195. The May 10
      // session's as-of anchor is unaffected — but the fingerprint of the
      // ANCHOR SET the pass resolves changed, so a re-walk may happen; the
      // VALUE must not move to the 195 anchor.
      await LocalDb.putMetricSeriesValue('2024-05-11', 'hr_ceiling_bpm', 195.0);
      await backfillVo2maxHistory(getProfileMap: () => {'age': 30});
      mine = (await LocalDb.vo2maxHistory())
          .where((r) => r['session_id'] == id)
          .first;
      expect(
        (mine['hr_max_bpm'] as num).toDouble(),
        187.0,
        reason:
            'a later ceiling is not historical evidence for an earlier '
            'session',
      );
      expect((mine['vo2max'] as num).toDouble(), closeTo(54.0, 0.5));
    },
  );

  test('a CORRECTED session timestamp re-walks the session', () async {
    const id = 'h-prov-ts';
    final startTs = DateTime(2024, 6, 12, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-06-11', 'rhr', 55.0);
    await backfillVo2maxHistory(getProfileMap: () => {'age': 30}, force: true);
    var mine = (await LocalDb.vo2maxHistory())
        .where((r) => r['session_id'] == id)
        .first;
    expect(mine['activity_ts'], startTs);

    // The user fixes the session's recorded start time (device clock was
    // off). The session DAY may move across the RHR seed, so the timestamp is
    // fingerprint-relevant and must re-walk.
    final correctedTs =
        DateTime(2024, 6, 12, 20).millisecondsSinceEpoch ~/ 1000;
    await LocalDb.putSession({
      'id': id,
      'start_ts': correctedTs,
      'end_ts': correctedTs + 1200,
      'type': 'run',
      'status': 'done',
      'duration_min': 20,
      'source': 'manual',
      'device_family': 'gen4',
      'created_at': correctedTs * 1000,
    });
    await backfillVo2maxHistory(getProfileMap: () => {'age': 30});
    mine = (await LocalDb.vo2maxHistory())
        .where((r) => r['session_id'] == id)
        .first;
    expect(
      mine['activity_ts'],
      correctedTs,
      reason: 'a corrected timestamp must replace the stale row',
    );
  });

  // ── Upgrade: a stale version payload re-runs the FULL pass ─────────────
  test('an OLD formula-version payload triggers a full re-walk', () async {
    const id = 'h-upgrade-1';
    final startTs = DateTime(2024, 6, 14, 8).millisecondsSinceEpoch ~/ 1000;
    await putSessionRow(id, 'run', startTs);
    await LocalDb.putWorkoutSplits(id, [
      {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
    ]);
    await LocalDb.putMetricSeriesValue('2024-06-13', 'rhr', 55.0);
    // First pass stores the current version gate.
    await backfillVo2maxHistory(getProfileMap: () => {'age': 30}, force: true);
    var mine = (await LocalDb.vo2maxHistory())
        .where((r) => r['session_id'] == id)
        .toList();
    expect(mine, hasLength(1));
    expect(mine.first['formula_version'], kVo2maxHistoryFormulaVersion);

    // Simulate an OLD payload: a version string from a previous release.
    await LocalDb.putComputeFreshness(
      kVo2maxHistoryFreshnessKey,
      jsonEncode({'formula_version': '1'}),
    );
    final res = await backfillVo2maxHistory(getProfileMap: () => {'age': 30});
    expect(
      res.didWork,
      isTrue,
      reason: 'a version-mismatched payload must re-run the full pass',
    );
    mine = (await LocalDb.vo2maxHistory())
        .where((r) => r['session_id'] == id)
        .toList();
    expect(
      mine,
      hasLength(1),
      reason: 'the full pass replaces in place, never duplicates',
    );
    expect(mine.first['formula_version'], kVo2maxHistoryFormulaVersion);
  });

  // ── Partial failure: a mid-pass write error keeps fingerprints stale ──
  // The smallest testable seam for "a failure after some successful session
  // writes": a SQLite trigger that fails the INSERT for one session id. No
  // production-code hook is needed — the guard is transactional per session,
  // so the failed session leaves no rows and the freshness payload must NOT
  // record its fingerprint as computed.
  test(
    'a write error mid-pass leaves the failed session un-fingerprinted',
    () async {
      const goodId = 'h-fail-good';
      const badId = 'h-fail-bad';
      final startTs = DateTime(2024, 6, 16, 8).millisecondsSinceEpoch ~/ 1000;
      await putSessionRow(goodId, 'run', startTs);
      await putSessionRow(badId, 'run', startTs + 60);
      for (final id in [goodId, badId]) {
        await LocalDb.putWorkoutSplits(id, [
          {'km': 1, 'meters': 1000.0, 'duration_sec': 330, 'avg_hr': 150.0},
        ]);
      }
      await LocalDb.putMetricSeriesValue('2024-06-15', 'rhr', 55.0);

      // Make every history INSERT for badId fail, AFTER the good session's
      // rows are already written (sessions are walked start_ts ASC).
      final db = await LocalDb.instance;
      await db.execute(
        "CREATE TRIGGER fail_bad_session BEFORE INSERT ON vo2max_history "
        "WHEN NEW.session_id = 'h-fail-bad' "
        "BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
      );
      await expectLater(
        backfillVo2maxHistory(getProfileMap: () => {'age': 30}, force: true),
        throwsA(anything),
      );
      await db.execute('DROP TRIGGER fail_bad_session');

      // The good session's rows survived...
      final rows = await LocalDb.vo2maxHistory();
      expect(rows.where((r) => r['session_id'] == goodId), isNotEmpty);
      // ...the failed session has none, and the pass must not have marked the
      // whole run current: the next pass re-walks and completes the job.
      final gate = await LocalDb.computeFreshness(kVo2maxHistoryFreshnessKey);
      expect(
        gate,
        isNull,
        reason:
            'a crashed pass must not store fingerprints as current — '
            'otherwise the failed session would never be retried',
      );
      final res = await backfillVo2maxHistory(getProfileMap: () => {'age': 30});
      expect(res.didWork, isTrue);
      final after = await LocalDb.vo2maxHistory();
      expect(
        after.where((r) => r['session_id'] == badId),
        isNotEmpty,
        reason:
            'the retry must complete the failed session without '
            'duplicating the good one',
      );
      expect(
        after.where((r) => r['session_id'] == goodId).length,
        1,
        reason:
            're-walk replaces in place — the good session gains no '
            'duplicate rows on retry',
      );
    },
  );
}
