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

  String _dayLabel(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$dd';
  }

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
    final gDay = DateTime(2026, 3, 9, 1);
    String gLabel(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    await putRows(gDay, [95, 96], 'ring-1');
    // The pre-change done fingerprint, built from the LIVE candidate —
    // a hardcoded epoch would only match under one timezone (the round-6
    // version hardcoded 2026-03-09T01:00 UTC and failed under
    // Europe/Berlin).
    final gCandidate = await LocalDb.ouraSpo2DayCandidate(gLabel(gDay));
    expect(gCandidate, isNotNull);
    final gFp = ouraSpo2CandidateFingerprint(gCandidate!);
    await LocalDb.setCursor(
        'health_oura_spo2_done:${gLabel(gDay)}', gFp);
    // Legacy round-4/5 keys alongside it.
    await LocalDb.setCursor('health_oura_spo2_through', gLabel(gDay));
    await LocalDb.setCursor('health_oura_spo2_scan_through', gLabel(gDay));
    await LocalDb.setCursor(
        'health_oura_spo2_skip:${gLabel(gDay)}', 'none');
    await runPass(store, interpretationVerified: true);
    // The bootstrap seeded the dirty set, the pass compared the
    // fingerprint, found it UNCHANGED, and made no store contact.
    expect(store.writeCalls, 0);
    expect(store.deleteCalls, 0);
    // The legacy keys are gone.
    expect(await LocalDb.getCursor('health_oura_spo2_through'), isNull);
    expect(await LocalDb.getCursor('health_oura_spo2_scan_through'),
        isNull);
    expect(
        await LocalDb.getCursor('health_oura_spo2_skip:${gLabel(gDay)}'),
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

  test('fairness: 35 dirty days with a retry day among them — the OTHER '
      'days all drain; the failing day keeps its own backoff', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    // 35 days, oldest 2026-01-01 .. 2026-02-04. The pass works NEWEST
    // FIRST: the first pass drains the 30 newest (Jan 6 .. Feb 4 plus
    // the failing Feb 5 attempt in its backoff), the second the rest.
    for (var i = 0; i < 35; i++) {
      await putRows(DateTime(2026, 1, 1 + i, 1), [95, 96], 'ring-1');
    }
    final failDay = DateTime(2026, 2, 5, 1);
    final failLabel =
        '${failDay.year}-${failDay.month.toString().padLeft(2, '0')}-'
        '${failDay.day.toString().padLeft(2, '0')}';
    store.refuseWrites.add(failLabel);
    await putRows(failDay, [90, 90], 'ring-1');
    await runPass(store, interpretationVerified: true);
    // EXACT: the pass works NEWEST FIRST — Feb 5 (the failing day) is
    // the newest, is attempted and fails first, then 29 of the 30-day
    // budget export (Feb 4 down to Jan 7). 29 successes + 1 failure.
    expect(store.own, hasLength(29));
    // The second pass drains the remaining 6 (Jan 6..Jan 1); the
    // failing day is in its 5-minute backoff and is SKIPPED, not
    // re-attempted.
    await runPass(store, interpretationVerified: true);
    expect(store.own, hasLength(35));
    expect(store.samplesOf(failLabel), isEmpty);
    expect((await LocalDb.ouraSpo2Retry(failLabel)).attempts, 1,
        reason: 'the failure was day-scoped: other days succeeded');
    // After the backoff and the store recovering, the day heals.
    store.refuseWrites.clear();
    await runPass(
      store,
      interpretationVerified: true,
      nowMs: () => DateTime.now().millisecondsSinceEpoch + 10 * 60000,
    );
    expect(store.samplesOf(failLabel), hasLength(1));
    expect((await LocalDb.ouraSpo2Retry(failLabel)).attempts, 0);
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

  test('global failure: 5 days fail (global stop); after the cause is '
      'fixed the days export WITHOUT day-backoff waiting', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    // 5 days, all failing (permission-denied shape): three consecutive
    // stop the pass GLOBALLY.
    for (var d = 1; d <= 5; d++) {
      store.refuseWrites
          .add(_dayLabel(DateTime(2026, 3, d)));
    }
    for (var d = 1; d <= 5; d++) {
      await putRows(DateTime(2026, 3, d, 1), [95, 96], 'ring-1');
    }
    await runPass(store, interpretationVerified: true);
    expect(store.own, isEmpty);
    // ONE global marker AND flat day counters (attempts == 1: the
    // 5-minute pacing that keeps the broken days from failing again on
    // the very next pass while the first stop holds nothing).
    final g = await LocalDb.ouraSpo2GlobalFail();
    expect(g.attempts, 1);
    // Newest first: Mar 5, Mar 4, Mar 3 were ATTEMPTED before the stop
    // and carry the flat counters; Mar 2 and Mar 1 were never reached.
    for (final d in [5, 4, 3]) {
      expect((await LocalDb.ouraSpo2Retry(_dayLabel(DateTime(2026, 3, d))))
          .attempts, 1,
          reason: 'flat day counters on a global stop');
    }
    for (final d in [2, 1]) {
      expect((await LocalDb.ouraSpo2Retry(_dayLabel(DateTime(2026, 3, d))))
          .attempts, 0,
          reason: 'never attempted: the stop came first');
    }
    // The days stay dirty (all of them).
    expect(await LocalDb.ouraSpo2DirtyDays(limit: 10), hasLength(5));
    // THE FIX: the cause is gone. The first stop holds NOTHING; the
    // flat day backoffs pace the retry at 5 minutes — past them (clock
    // seam) the days export in the VERY NEXT pass.
    store.refuseWrites.clear();
    await runPass(
      store,
      interpretationVerified: true,
      nowMs: () => DateTime.now().millisecondsSinceEpoch + 6 * 60000,
    );
    expect(store.own, hasLength(5),
        reason: 'the days drained after the flat 5-minute backoff');
    // Store success cleared the global state.
    expect((await LocalDb.ouraSpo2GlobalFail()).attempts, 0);
  });

  test('a single permanently failing day NEXT TO successful days keeps '
      'its DAY backoff (not global)', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    final failLabel = _dayLabel(DateTime(2026, 3, 9));
    store.refuseWrites.add(failLabel);
    await putRows(DateTime(2026, 3, 9, 1), [90, 90], 'ring-1');
    await putRows(DateTime(2026, 3, 10, 1), [95, 96], 'ring-1');
    await runPass(store, interpretationVerified: true);
    // The other day exported; the failure was day-scoped.
    expect(store.own, hasLength(1));
    expect((await LocalDb.ouraSpo2Retry(failLabel)).attempts, 1);
    expect((await LocalDb.ouraSpo2GlobalFail()).attempts, 0,
        reason: 'one failure next to a success is not a global cause');
    // After the 5-minute DAY backoff it heals.
    store.refuseWrites.clear();
    await runPass(
      store,
      interpretationVerified: true,
      nowMs: () => DateTime.now().millisecondsSinceEpoch + 10 * 60000,
    );
    expect(store.own, hasLength(2));
  });

  test('same-adapter upsert does NOT re-mark: the dirty token stays '
      'identical, an unchanged candidate is never re-verified', () async {
    await pairRing('ring-1');
    await putRows(DateTime(2026, 3, 9, 1), [95, 96], 'ring-1');
    final before = (await LocalDb.ouraSpo2DirtyDays()).single;
    // The Oura sync re-touches the row with the SAME adapter id.
    await pairRing('ring-1');
    await pairRing('ring-1');
    final after = await LocalDb.ouraSpo2DirtyDays();
    expect(after, hasLength(1));
    expect(after.single.token, before.token,
        reason: 'an unchanged pairing must not mint a new dirty token');
  });

  test('adapter change away from oura removes the candidates: the days '
      'turn dirty and the stale exports clean up', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(DateTime(2026, 3, 9, 1), [95, 96], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09'), hasLength(1));
    // The device is re-paired as a DIFFERENT adapter: its days lose
    // candidacy and the prior export must be cleaned up.
    await LocalDb.upsertDevice(
        id: 'ring-1', adapterId: 'whoop_gen4', remoteId: 'x2');
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09'), isEmpty);
    expect(await LocalDb.getCursor('health_oura_spo2_done:2026-03-09'),
        isNull);
  });

  test('restore drops foreign export markers and re-seeds the observed '
      'days dirty (a done marker is not export proof on this phone)',
      () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    final day = DateTime.now().subtract(const Duration(days: 3));
    final label = _dayLabel(day);
    await putRows(day, [95, 96], 'ring-1');
    // A done marker as ANOTHER INSTALL would have written it — after a
    // restore it must not count as export proof here.
    await LocalDb.setCursor('health_oura_spo2_done:$label',
        'v1|ring-1|95.500000000000000|2|1|2');
    // Drain the dirty set to isolate the restore's effect.
    for (final d in await LocalDb.ouraSpo2DirtyDays(limit: 100)) {
      await LocalDb.clearOuraSpo2DirtyIfUnchanged(d.date, d.token);
    }
    // A backup file with the same observation rows.
    final dir = await databaseFactory.getDatabasesPath();
    final srcPath = p.join(dir, 'restore_marker_test.db');
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
        'CREATE TABLE observation (device_id TEXT NOT NULL DEFAULT "", '
        'ts_ms INTEGER NOT NULL, date TEXT NOT NULL, '
        'source_kind TEXT NOT NULL, vendor_key TEXT, key TEXT, '
        'value REAL, unit TEXT, attribution TEXT NOT NULL, '
        'CHECK (vendor_key IS NOT NULL OR key IS NOT NULL))');
    await src.insert('observation', {
      'device_id': 'ring-1',
      'ts_ms': day.millisecondsSinceEpoch,
      'date': label,
      'source_kind': 'vendor',
      'vendor_key': 'spo2',
      'value': 97.0,
      'unit': '%',
      'attribution': 'Oura',
    });
    await LocalDb.importFromDbFile(srcPath);
    // The foreign done marker is gone; the day is dirty; the next pass
    // WRITES (the local health store has nothing).
    expect(await LocalDb.getCursor('health_oura_spo2_done:$label'), isNull);
    expect((await LocalDb.ouraSpo2DirtyDays()).map((d) => d.date),
        contains(label));
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf(label), hasLength(1),
        reason: 'the restore re-exported: the marker was not proof');
    // Hand-computed over the merged rows: the backup's 97 REPLACES the
    // same-second local 95 (the observation identity index), leaving
    // [97, 96] -> mean 96.5.
    expect(store.samplesOf(label).single.$3, closeTo(96.5, 1e-10));
    await src.close();
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('a) three permanently broken NEWEST days do not starve ten healthy '
      'older days — all ten export across passes; the broken days keep '
      'attempts == 1', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    // Three permanently broken NEWEST days (Mar 11..13); ten healthy
    // older days behind them (Mar 1..10). This is the audit's exact
    // starvation shape: newest-first, the broken days fail before any
    // healthy day is reached.
    final broken = <String>[];
    for (var d = 11; d <= 13; d++) {
      final day = DateTime(2026, 3, d);
      final label = _dayLabel(day);
      broken.add(label);
      store.refuseWrites.add(label);
      await putRows(day, [95, 96], 'ring-1');
    }
    for (var d = 1; d <= 10; d++) {
      await putRows(DateTime(2026, 3, d), [95, 96], 'ring-1');
    }
    // Pass 1: the three broken days fail first (newest first), the pass
    // stops globally, the day counters are written FLAT.
    await runPass(store, interpretationVerified: true);
    expect(store.own, isEmpty);
    for (final b in broken) {
      expect((await LocalDb.ouraSpo2Retry(b)).attempts, 1,
          reason: 'flat: attempts stay 1 on a global stop');
    }
    // Pass 2 (+2 min, INSIDE the broken days' flat 5-minute backoff):
    // the first global stop holds NOTHING, so the pass runs; the broken
    // days are not retry-due yet and SKIP; the ten healthy days
    // export. This is the window the flat design exists for — under
    // the round-7 code (no day counters on a global stop) these ten
    // days were starved FOREVER, because the broken days were
    // attempts-0 retry-due again on every pass.
    await runPass(
      store,
      interpretationVerified: true,
      nowMs: () => DateTime.now().millisecondsSinceEpoch + 2 * 60000,
    );
    expect(store.own, hasLength(10),
        reason: 'the healthy older days were reached');
    // b) The cause is fixed: past the flat 5-minute day backoff
    // (clock seam) the three broken days export.
    for (final b in broken) {
      store.refuseWrites.remove(b);
    }
    await runPass(
      store,
      interpretationVerified: true,
      nowMs: () => DateTime.now().millisecondsSinceEpoch + 6 * 60000,
    );
    expect(store.own, hasLength(13),
        reason: 'all three broken days exported after the flat backoff');
  });

  test('c) a global marker survives an unchanged day: no store contact, '
      'the streak keeps counting', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    // PASS 1 — ONLY the unchanged day: it was exported earlier with
    // exactly this fingerprint, so re-processing it must make NO store
    // contact and must NOT clear the global marker.
    final day1 = DateTime(2026, 3, 10);
    await putRows(day1, [95, 96], 'ring-1');
    final c1 = await LocalDb.ouraSpo2DayCandidate(_dayLabel(day1));
    // A global marker in its hold window (attempts == 2 -> 5 minutes,
    // stamped just now) — the pass must run PAST it via the clock seam.
    await LocalDb.setCursor('health_oura_spo2_global_fail',
        '2|${DateTime.now().millisecondsSinceEpoch}');
    await LocalDb.setCursor('health_oura_spo2_done:${_dayLabel(day1)}',
        ouraSpo2CandidateFingerprint(c1!));
    final writesBefore = store.writeCalls;
    final deletesBefore = store.deleteCalls;
    await runPass(
      store,
      interpretationVerified: true,
      nowMs: () => DateTime.now().millisecondsSinceEpoch + 6 * 60000,
    );
    expect(store.writeCalls, writesBefore,
        reason: 'an unchanged day makes no store contact');
    expect(store.deleteCalls, deletesBefore,
        reason: 'an unchanged day makes no store contact');
    expect((await LocalDb.ouraSpo2GlobalFail()).attempts, 2,
        reason: 'an unchanged day is not proof the store works');
    // PASS 2 — a FAILING day after it: the marker still holds no
    // store-success proof, the day takes its (real, day-scoped)
    // backoff — the streak was never reset by the unchanged day.
    final day2 = DateTime(2026, 3, 9);
    store.refuseWrites.add(_dayLabel(day2));
    await putRows(day2, [90, 90], 'ring-1');
    await runPass(
      store,
      interpretationVerified: true,
      nowMs: () => DateTime.now().millisecondsSinceEpoch + 6 * 60000,
    );
    expect((await LocalDb.ouraSpo2GlobalFail()).attempts, 2,
        reason: 'a failed day is no proof either — the marker survives');
    expect(
        (await LocalDb.ouraSpo2Retry(_dayLabel(day2))).attempts, 1);
  });

  test('d) the global backoff is CLAMPED at 60 minutes: attempts == 100 '
      'is due after 60, not after 500', () async {
    await pairRing('ring-1');
    final t0 = DateTime.now().millisecondsSinceEpoch;
    await LocalDb.setCursor('health_oura_spo2_global_fail', '100|$t0');
    // Direct probe of the clamp through the pass's own gate: a pass at
    // +59 min is held, at +61 min runs (it will process nothing dirty,
    // but it must not print the "backoff holds" bail).
    final store = StatefulSpo2Store();
    await putRows(DateTime(2026, 3, 9), [95, 96], 'ring-1');
    // At wall-now the 60-minute clamp HOLDS the pass: nothing exports.
    await runPass(store, interpretationVerified: true);
    expect(store.own, isEmpty, reason: 'the clamp holds before +60 min');
    final g = await LocalDb.ouraSpo2GlobalFail();
    expect(g.attempts, 100);
    // The clamp: 5 * (100 - 1) clamped to 60 -> due at +60 min. The
    // next pass with a clock 61 minutes ahead is NOT held (the day
    // drains).
    await runPass(
      store,
      interpretationVerified: true,
      nowMs: () => t0 + 61 * 60000,
    );
    expect(store.own, hasLength(1),
        reason: 'the global backoff was due after 60 minutes, not 500');
  });

  test('e) resetOuraSpo2FailureState drops the global marker and every '
      'day retry; the next pass exports without waiting', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    final label = _dayLabel(DateTime(2026, 3, 9));
    await putRows(DateTime(2026, 3, 9), [95, 96], 'ring-1');
    // A failed day + a global marker, both stamped NOW: the global
    // backoff (5 * (5 - 1) = 20 min) and the day retry (20 min for
    // attempt 3) are both ACTIVE.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await LocalDb.setCursor('health_oura_spo2_retry:$label', '3|$nowMs');
    await LocalDb.setCursor('health_oura_spo2_global_fail', '5|$nowMs');
    // Without the reset nothing exports: the global gate holds.
    await runPass(store, interpretationVerified: true);
    expect(store.own, isEmpty);
    // THE RESET: the explicit user action clears both.
    await LocalDb.resetOuraSpo2FailureState();
    expect((await LocalDb.ouraSpo2GlobalFail()).attempts, 0);
    expect((await LocalDb.ouraSpo2Retry(label)).attempts, 0);
    // The very next pass (same wall clock!) exports without waiting.
    await runPass(store, interpretationVerified: true);
    expect(store.own, hasLength(1),
        reason: 'the reset removed the waiting, not the clock');
  });

  test('f) two PARALLEL upsertDevice calls with the same adapterId: the '
      'dirty token is stable afterwards (no re-mark churn)', () async {
    await pairRing('ring-1');
    await putRows(DateTime(2026, 3, 9), [95, 96], 'ring-1');
    final before = (await LocalDb.ouraSpo2DirtyDays()).single;
    // Two concurrent same-adapter upserts: whichever wins, the adapter
    // did not CHANGE, so no new token may appear.
    await Future.wait([
      pairRing('ring-1'),
      pairRing('ring-1'),
    ]);
    final after = await LocalDb.ouraSpo2DirtyDays();
    expect(after, hasLength(1));
    expect(after.single.token, before.token,
        reason: 'a same-adapter re-mark would mint a fresh token and '
            'defeat compare-and-clear');
  });

  test('pass: a global marker with a FUTURE stamp does not block '
      '(backwards clock never holds)', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(DateTime(2026, 3, 9, 1), [95, 96], 'ring-1');
    final t0 = DateTime.now().millisecondsSinceEpoch;
    // A global marker stamped 3 h in the future (the clock went back):
    // under the pre-fix pass this held until the clock caught up with
    // the stamp; the day backoff treats the same case as due.
    await LocalDb.setCursor(
        'health_oura_spo2_global_fail', '5|${t0 + 3 * 3600000}');
    await runPass(
      store,
      interpretationVerified: true,
      nowMs: () => t0,
    );
    expect(store.samplesOf('2026-03-09'), hasLength(1),
        reason: 'the pass ran despite the future-stamped marker');
  });

  test('flat counters KEEP an existing escalation (no reset to 1)', () async {
    final store = StatefulSpo2Store();
    // Three newest days failing on DELETE (the store's clear window).
    for (final d in [10, 11, 12]) {
      store.refuseDeletes.add(_dayLabel(DateTime(2026, 3, d)));
    }
    await pairRing('ring-1');
    for (final d in [9, 10, 11, 12]) {
      await putRows(DateTime(2026, 3, d, 1), [95, 96], 'ring-1');
    }
    final t0 = DateTime.now().millisecondsSinceEpoch;
    // 03-12 already carries a REAL day-scoped escalation (attempt 6 =
    // 160-minute backoff) and its stamp is old enough to be retry-due
    // again (5 << 5 = 160 minutes; the stamp is 200 minutes old).
    await LocalDb.setCursor(
        'health_oura_spo2_retry:2026-03-12', '6|${t0 - 200 * 60000}');
    // This pass: 03-12 is retry-DUE (200 > 160), fails; 03-11 and
    // 03-10 fail after it -> global stop with FLAT counters.
    await runPass(
      store,
      interpretationVerified: true,
      nowMs: () => t0,
    );
    final r12 = await LocalDb.ouraSpo2Retry('2026-03-12');
    final r11 = await LocalDb.ouraSpo2Retry('2026-03-11');
    expect(r12.attempts, 6,
        reason: 'the escalation was KEPT, not reset to 1');
    expect(r12.lastMs, t0, reason: 'but the stamp is fresh');
    expect(r11.attempts, 1, reason: 'a fresh failure starts at 1');
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
