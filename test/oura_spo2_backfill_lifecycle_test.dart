// The Oura-SpO2 DIRTY-SET lifecycle against the PRODUCTION entry point.
//
// `HealthExporter.debugRunSpo2Pass` IS `_exportOuraSpo2Pass` — the same
// bootstrap, dirty enumeration, atomic candidate, gate, fingerprint
// compare, retry backoff and compare-and-clear production runs after
// exportAll. NOTHING is re-wired here. The ONLY doubles are the
// health-store operations (a STATEFUL store counting every contact) and
// the clock (`nowMs`) for the backoff cases.
//
// Round-6 audit cases A-I plus the fairness/idempotence/midnight
// regressions. Every expectation is hand-computed. `pairRing` uses the
// PRODUCTION pairing writer (`LocalDb.upsertDevice`), so the device-hook
// dirty marking is exercised by the tests that need it.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_edge/health/health_export.dart';

/// A STATEFUL health-store double: keeps real own-sample state, deletes
/// only window-own samples, holds seeded FOREIGN samples untouched,
/// injects per-day write/delete failures, and counts EVERY contact so
/// idempotence is provable by absence.
class StatefulSpo2Store {
  final own = <(String, int, int, double)>[];
  final foreign = <(int, int, double)>[];
  final refuseWrites = <String>{};
  final refuseDeletes = <String>{};
  int writeCalls = 0;
  int deleteCalls = 0;

  Future<bool> deleteWindow(String day, DateTime start, DateTime end) async {
    deleteCalls++;
    if (refuseDeletes.contains(day)) return false;
    final s = start.millisecondsSinceEpoch;
    final e = end.millisecondsSinceEpoch;
    own.removeWhere((x) => x.$2 >= s && x.$2 < e);
    return true;
  }

  Future<bool> write(
      String day, double value, DateTime start, DateTime end) async {
    writeCalls++;
    if (refuseWrites.contains(day)) return false;
    own.add((day, start.millisecondsSinceEpoch, end.millisecondsSinceEpoch,
        value));
    return true;
  }

  List<(int, int, double)> samplesOf(String day) =>
      [for (final s in own) if (s.$1 == day) (s.$2, s.$3, s.$4)]..sort();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'oura_spo2_backfill_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
  });
  tearDown(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  List<Observation> rowsAt(DateTime start, List<num> values) => [
        for (var i = 0; i < values.length; i++)
          Observation(
            at: start.add(Duration(seconds: i)),
            sourceKind: ObservationSource.vendor,
            vendorKey: 'spo2',
            value: values[i],
            unit: '%',
            attribution: 'Oura',
          ),
      ];

  Future<void> putRows(DateTime start, List<num> values, String ring) =>
      LocalDb.putObservations(rowsAt(start, values), deviceId: ring);

  /// The PRODUCTION pairing writer — the same call `OuraLink` makes, so
  /// the device-hook dirty marking runs exactly as in production.
  Future<void> pairRing(String id) => LocalDb.upsertDevice(
        id: id,
        adapterId: 'oura',
        remoteId: 'test-$id',
        label: 'Test $id',
      );

  Future<void> runPass(
    StatefulSpo2Store store, {
    required bool interpretationVerified,
    int Function()? nowMs,
  }) async {
    await HealthExporter.shared.debugRunSpo2Pass(
      write: (v, s, e) {
        final day =
            "${s.year}-${s.month.toString().padLeft(2, '0')}-${s.day.toString().padLeft(2, '0')}";
        return store.write(day, v, s, e);
      },
      deleteWindow: (s, e) {
        final day =
            "${s.year}-${s.month.toString().padLeft(2, '0')}-${s.day.toString().padLeft(2, '0')}";
        return store.deleteWindow(day, s, e);
      },
      interpretationVerified: interpretationVerified,
      nowMs: nowMs,
    );
  }

  test('A: correction on the NEWEST day after 35 exported days — the '
      'dirty set has no 30-day blind spot', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    // 35 days of two samples each: [95, 96] -> mean 95.5.
    for (var i = 0; i < 35; i++) {
      await putRows(DateTime(2026, 1, 1 + i, 1), [95, 96], 'ring-1');
    }
    for (var pass = 0; pass < 3; pass++) {
      await runPass(store, interpretationVerified: true);
    }
    expect(store.own, hasLength(35));
    final calls = store.writeCalls;
    // A replay that CORRECTS the newest day (2026-01-35 normalises to
    // 2026-02-04): [95,96] -> [90,96] -> mean 93.
    await putRows(DateTime(2026, 2, 4, 1), [90, 96], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.writeCalls, calls + 1);
    expect(store.samplesOf('2026-02-04').single.$3, 93);
  });

  test('B: never-seen days OLDER than the newest exported day still '
      'export; then idempotence — no store contact', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(DateTime(2026, 3, 10, 1), [95, 96], 'ring-1');
    await runPass(store, interpretationVerified: true);
    // Two days that were never seen before, both OLDER than the one
    // already exported.
    await putRows(DateTime(2026, 3, 8, 1), [90, 92], 'ring-1');
    await putRows(DateTime(2026, 3, 9, 1), [93, 93], 'ring-1');
    await runPass(store, interpretationVerified: true);
    // Hand-computed means: 91 and 93.
    expect(store.samplesOf('2026-03-08').single.$3, 91);
    expect(store.samplesOf('2026-03-09').single.$3, 93);
    // Idempotence: unchanged days make NO store contact.
    final calls = store.writeCalls;
    final deletes = store.deleteCalls;
    await runPass(store, interpretationVerified: true);
    await runPass(store, interpretationVerified: true);
    expect(store.writeCalls, calls);
    expect(store.deleteCalls, deletes);
  });

  test('C: forgotten-ring days NEWER than the last success, then '
      're-pair — the device hook marks them dirty', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(DateTime(2026, 3, 1, 1), [95, 96], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.own, hasLength(1));
    // Six days of a ring that has NO pairing row: no candidate, and
    // they sit NEWER than the exported day — under the round-5 cursors
    // these would never have been re-assessed after a re-pair.
    for (var d = 5; d <= 10; d++) {
      await putRows(DateTime(2026, 3, d, 1), [97, 98], 'ring-gone');
    }
    await runPass(store, interpretationVerified: true);
    expect(store.own, hasLength(1), reason: 'ring-gone has no candidate');
    // Re-pair through the PRODUCTION writer: the hook marks its days
    // dirty, the next pass exports them.
    await pairRing('ring-gone');
    await runPass(store, interpretationVerified: true);
    expect(store.own, hasLength(7));
    expect(store.samplesOf('2026-03-10').single.$3, 97.5);
  });

  test('D: one permanently failing day never blocks the others; the '
      'backoff retries it and the retry state is exact', () async {
    final store = StatefulSpo2Store()..refuseDeletes.add('2026-03-09');
    await pairRing('ring-1');
    await putRows(DateTime(2026, 3, 9, 1), [90, 90], 'ring-1');
    await putRows(DateTime(2026, 3, 10, 1), [95, 96], 'ring-1');
    await runPass(store, interpretationVerified: true);
    // The OTHER day exported; the failing one left no sample.
    expect(store.samplesOf('2026-03-10'), hasLength(1));
    expect(store.samplesOf('2026-03-09'), isEmpty);
    // Exact retry state: one attempt recorded.
    final retry = await LocalDb.ouraSpo2Retry('2026-03-09');
    expect(retry.attempts, 1);
    // The day stays dirty.
    final dirty = await LocalDb.ouraSpo2DirtyDays(limit: 100);
    expect(dirty.map((d) => d.date), contains('2026-03-09'));
    // After the backoff (5 minutes) and the store recovering, the retry
    // heals — driven through the clock seam.
    store.refuseDeletes.clear();
    await runPass(store, interpretationVerified: true);
    // Not yet due: within the same clock reading it stays pending.
    expect(store.samplesOf('2026-03-09'), isEmpty);
    await runPass(
      store,
      interpretationVerified: true,
      nowMs: () => DateTime.now().millisecondsSinceEpoch + 10 * 60000,
    );
    expect(store.samplesOf('2026-03-09'), hasLength(1));
    // Success cleared the retry state.
    expect((await LocalDb.ouraSpo2Retry('2026-03-09')).attempts, 0);
  });

  test('E: gate closed keeps every day dirty (all 40); opening drains '
      'them across bounded passes', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    for (var d = 1; d <= 40; d++) {
      await putRows(DateTime(2026, 3, d, 1), [95, 96], 'ring-1');
    }
    await runPass(store, interpretationVerified: false);
    expect(store.own, isEmpty);
    expect(await LocalDb.ouraSpo2DirtyDays(limit: 100), hasLength(40));
    for (var pass = 0; pass < 3; pass++) {
      await runPass(store, interpretationVerified: true);
    }
    expect(store.own, hasLength(40));
    expect(await LocalDb.ouraSpo2DirtyDays(limit: 100), isEmpty);
  });

  test('F: compare-and-clear keeps a marker changed during the pass; '
      'the substr offset is exact', () async {
    await pairRing('ring-1');
    await putRows(DateTime(2026, 3, 9, 1), [95, 96], 'ring-1');
    final read = (await LocalDb.ouraSpo2DirtyDays()).single;
    // A change lands between the read and the clear: the re-mark gives
    // the day a NEW token, so the stale clear must not remove it.
    await putRows(DateTime(2026, 3, 9, 1), [95, 97], 'ring-1');
    await LocalDb.clearOuraSpo2DirtyIfUnchanged(read.date, read.token);
    final after = await LocalDb.ouraSpo2DirtyDays();
    expect(after, hasLength(1));
    // The substr offset extracts the exact date — this also guards the
    // prefix arithmetic (no off-by-five this time: prefix length + 1).
    expect(after.single.date, '2026-03-09');
  });

  test('G: bootstrap over pre-existing done fingerprints — an unchanged '
      'day costs NO store contact; legacy keys are removed', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(DateTime(2026, 3, 9, 1), [95, 96], 'ring-1');
    // Simulate a round-4/5 install: a done fingerprint written by the
    // OLD walk plus its legacy cursor keys.
    await LocalDb.setCursor('health_oura_spo2_done:2026-03-09',
        'v1|ring-1|95.500000000000000|2|1773018000000|1773018001000');
    await LocalDb.setCursor('health_oura_spo2_through', '2026-03-09');
    await LocalDb.setCursor('health_oura_spo2_scan_through', '2026-03-09');
    await LocalDb.setCursor('health_oura_spo2_skip:2026-03-09', 'none');
    await runPass(store, interpretationVerified: true);
    // The bootstrap seeded the dirty set, the pass compared the
    // fingerprint, found it UNCHANGED, and made no store contact.
    expect(store.writeCalls, 0);
    expect(store.deleteCalls, 0);
    // The legacy keys are gone.
    expect(await LocalDb.getCursor('health_oura_spo2_through'), isNull);
    expect(await LocalDb.getCursor('health_oura_spo2_scan_through'),
        isNull);
    expect(await LocalDb.getCursor('health_oura_spo2_skip:2026-03-09'),
        isNull);
    // And the day is no longer dirty.
    expect(await LocalDb.ouraSpo2DirtyDays(), isEmpty);
  });

  test('H: cleanup of a vanished candidate fails, then heals after the '
      'backoff', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(DateTime(2026, 3, 9, 1), [95, 96], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09'), hasLength(1));
    // The ring is forgotten: the candidate vanishes, the cleanup must
    // remove the stale export — but the store refuses the delete.
    await LocalDb.deleteDevice('ring-1');
    store.refuseDeletes.add('2026-03-09');
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09'), hasLength(1),
        reason: 'the cleanup delete failed — the sample stays');
    expect((await LocalDb.ouraSpo2Retry('2026-03-09')).attempts, 1);
    // The store recovers; while the backoff holds, the cleanup does
    // NOT run — the stale sample stays, visibly, until the retry is due.
    store.refuseDeletes.clear();
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09'), hasLength(1),
        reason: 'still within the 5-minute backoff');
    await runPass(
      store,
      interpretationVerified: true,
      nowMs: () => DateTime.now().millisecondsSinceEpoch + 10 * 60000,
    );
    expect(store.samplesOf('2026-03-09'), isEmpty);
    expect(await LocalDb.getCursor('health_oura_spo2_done:2026-03-09'),
        isNull);
  });

  test('midnight correction: day A cleaned up, day B exported, foreign '
      'samples on BOTH days untouched', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    // RELATIVE dates: inside the recent-days sweep window regardless of
    // the wall clock the test runs under.
    final now = DateTime.now();
    final dayA = DateTime(now.year, now.month, now.day - 2, 1);
    final dayB = DateTime(now.year, now.month, now.day - 1, 2);
    String label(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final dayALabel = label(dayA);
    final dayBLabel = label(dayB);
    await putRows(dayA, [90, 90, 100], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf(dayALabel), hasLength(1));
    store.foreign.add((
      dayA.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      dayA.add(const Duration(minutes: 6)).millisecondsSinceEpoch,
      88.0
    ));
    store.foreign.add((
      dayB.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
      dayB.add(const Duration(minutes: 2)).millisecondsSinceEpoch,
      89.0
    ));
    // The anchor is corrected: the seconds move from day A to day B. A
    // raw delete (a path outside the hooks — the merge hook covers the
    // production restore) is caught by the once-per-day recent sweep;
    // resetting the sweep marker models the next local day.
    final db = await LocalDb.instance;
    await db.delete('observation',
        where: "vendor_key = 'spo2' AND date = ?", whereArgs: [dayALabel]);
    await LocalDb.deleteCursor('health_oura_spo2_recent_sweep');
    await putRows(dayB, [90, 90, 100], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf(dayALabel), isEmpty);
    final b = store.samplesOf(dayBLabel);
    expect(b, hasLength(1));
    expect(b.single.$3, closeTo(93.33333333333333, 1e-10));
    expect(store.foreign, hasLength(2));
  });

  test('fairness: 35 dirty days with retry days among them — older days '
      'still make progress', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    for (var i = 0; i < 35; i++) {
      await putRows(DateTime(2026, 1, 1 + i, 1), [95, 96], 'ring-1');
    }
    // A few newer days that fail: they take backoff, but must not
    // starve the older ones.
    store.refuseWrites.add('2026-02-05');
    await putRows(DateTime(2026, 2, 5, 1), [90, 90], 'ring-1');
    await runPass(store, interpretationVerified: true);
    // The pass bounded at 30 days: the oldest days progressed.
    expect(store.own.length, greaterThanOrEqualTo(29));
    // A second pass works through the rest (the failing day stays in
    // backoff, everything else drains).
    await runPass(store, interpretationVerified: true);
    expect(store.own.length, greaterThanOrEqualTo(35));
  });

  test('a vanished candidate with NO prior export: nothing to do, the '
      'marker clears without any store contact', () async {
    final store = StatefulSpo2Store();
    // A ring with rows but no pairing: no candidate, no done marker.
    await putRows(DateTime(2026, 3, 9, 1), [95, 96], 'ring-never-paired');
    await runPass(store, interpretationVerified: true);
    expect(store.own, isEmpty);
    expect(store.writeCalls, 0);
    expect(store.deleteCalls, 0);
    // nothingToDo cleared the dirty marker — the day is not re-walked.
    expect(await LocalDb.ouraSpo2DirtyDays(), isEmpty,
        reason: 'the recent-days sweep is once per local day; within the '
            'same test the sweep has already run for today');
  });

  test('no legacy keys are ever written by the new pass', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(DateTime(2026, 3, 9, 1), [95, 96], 'ring-1');
    await runPass(store, interpretationVerified: true);
    await runPass(store, interpretationVerified: true);
    final db = await LocalDb.instance;
    final legacy = await db.rawQuery(
      "SELECT name FROM sync_cursor WHERE "
      "name IN ('health_oura_spo2_through',"
      "'health_oura_spo2_scan_through') "
      "OR substr(name, 1, 22) = 'health_oura_spo2_skip:'",
    );
    expect(legacy, isEmpty);
  });
}
