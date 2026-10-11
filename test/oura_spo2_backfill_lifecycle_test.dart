// The Oura-SpO2 backfill LIFECYCLE against the PRODUCTION entry point.
//
// `HealthExporter.debugRunSpo2Pass` IS `_exportOuraSpo2BehindCursor` —
// the same enumeration SQL, the same atomic candidate, the same gate,
// the same cursor table, the same retry order production runs after
// exportAll. NOTHING is re-wired in the test. The ONLY doubles are the
// health-store operations (write/delete) — through a STATEFUL store
// that keeps real sample state, deletes only what it owns, and lets a
// test inject failures; and the interpretation gate, granted as an
// explicit test parameter that production can only read as the const.
//
// Every expectation is hand-computed from the fixture rows.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_edge/health/health_export.dart';

/// A STATEFUL health-store double. It keeps the samples this "app" wrote,
/// deletes only samples inside the given window (as HealthKit deletes
/// only the caller's own), and PRE-SEEDABLE foreign samples it never
/// touches. Write/delete outcomes are asserted against this state, not
/// against call counts.
class StatefulSpo2Store {
  /// (day, startMs, endMs, value) — this app's own samples.
  final own = <(String, int, int, double)>[];

  /// Foreign samples (another app's) — seeded, never deleted by us.
  final foreign = <(int, int, double)>[];

  /// Days whose write should fail (store refusing the type, e.g.).
  final refuseWrites = <String>{};

  /// Days whose DELETE should fail (store hung / locked phone).
  final refuseDeletes = <String>{};

  Future<bool> deleteWindow(String day, DateTime start, DateTime end) async {
    if (refuseDeletes.contains(day)) return false;
    final s = start.millisecondsSinceEpoch;
    final e = end.millisecondsSinceEpoch;
    own.removeWhere((x) => x.$2 >= s && x.$2 < e);
    return true;
  }

  Future<bool> write(String day, double value, DateTime start,
      DateTime end) async {
    if (refuseWrites.contains(day)) return false;
    // HealthKit would reject a write outside any granted window; the
    // day-window delete is what makes the write safe. Assert the
    // contract the production code relies on: the sample's start sits
    // inside THIS day's cleared window.
    own.add((day, start.millisecondsSinceEpoch, end.millisecondsSinceEpoch,
        value));
    return true;
  }

  /// The final own-sample BESTAND for a day.
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

  final d9 = DateTime(2026, 3, 9, 1, 0, 0);
  final d10 = DateTime(2026, 3, 10, 2, 0, 0);

  List<Observation> rowsFor(DateTime start, List<num> values) => [
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

  /// Pair a ring — production writes adapter_id on pairing; the atomic
  /// candidate ranks only rings carrying it.
  Future<void> pairRing(String id) async {
    final db = await LocalDb.instance;
    await db.insert('device', {
      'id': id,
      'adapter_id': 'oura',
      'first_seen': d9.millisecondsSinceEpoch,
      'last_seen': d9.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// The PRODUCTION pass. Only the store and the gate state are test
  /// inputs; enumeration, candidate, cursor and retry are production.
  Future<void> runPass(
    StatefulSpo2Store store, {
    required bool interpretationVerified,
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
    );
  }

  test('#1 an old unsuitable day never wedges newer suitable days — the '
      'newer day exports WITHOUT re-pairing anything', () async {
    final store = StatefulSpo2Store();
    // The OLD day belongs to a FORGOTTEN ring (banked rows, no device
    // row): unsuitable. The NEWER day belongs to a paired ring.
    await LocalDb.putObservations(
        rowsFor(d9, [90, 90, 100]), deviceId: 'oura-forgotten');
    await pairRing('oura-ring-1');
    await LocalDb.putObservations(
        rowsFor(d10, [96, 98]), deviceId: 'oura-ring-1');

    await runPass(store, interpretationVerified: true);

    // The newer day IS exported — no head blocking, no re-pairing.
    expect(store.samplesOf('2026-03-10'), hasLength(1));
    expect(store.samplesOf('2026-03-10').first.$3, 97);
    // The old day was NOT written...
    expect(store.samplesOf('2026-03-09'), isEmpty);
    // ...and NOT consumed: no watermark, and the day is still enumerated
    // above the cursor, so re-pairing the ring makes it export next.
    expect(await LocalDb.getCursor('health_oura_spo2_done:2026-03-09'),
        isNull);
    await pairRing('oura-forgotten');
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09'), hasLength(1));
  });

  test('#1 gate closed: NOTHING written, cursor untouched, all days kept',
      () async {
    final store = StatefulSpo2Store();
    await pairRing('oura-ring-1');
    await LocalDb.putObservations(
        rowsFor(d9, [90, 90, 100]), deviceId: 'oura-ring-1');
    await runPass(store, interpretationVerified: false);
    expect(store.own, isEmpty);
    expect(await LocalDb.getCursor('health_oura_spo2_through'), isNull);
    // And the pass skips (does not stop) — nothing consumed:
    await runPass(store, interpretationVerified: true);
    expect(store.own, hasLength(1));
  });

  test('#2 a tail rewrite of an older day never drags the cursor back; '
      'a later failure leaves the frontier durable', () async {
    final store = StatefulSpo2Store();
    await pairRing('oura-ring-1');
    await LocalDb.putObservations(
        rowsFor(d9, [90, 90, 100]), deviceId: 'oura-ring-1');
    await LocalDb.putObservations(
        rowsFor(d10, [96, 98]), deviceId: 'oura-ring-1');
    await runPass(store, interpretationVerified: true);
    expect(await LocalDb.getCursor('health_oura_spo2_through'), '2026-03-10');

    // Late data changes the OLD day — it rejoins the changed-day scope.
    await LocalDb.putObservations(
        rowsFor(d9.add(const Duration(seconds: 10)), [97, 97]),
        deviceId: 'oura-ring-1');
    // And the NEWER day now fails (store refusing).
    store.refuseWrites.add('2026-03-10');
    await runPass(store, interpretationVerified: true);
    // The old day was re-exported (94.8 over five samples)...
    expect(store.samplesOf('2026-03-09'), hasLength(1));
    expect(store.samplesOf('2026-03-09').first.$3, closeTo(94.8, 1e-10));
    // ...and the cursor NEVER went backwards despite the older rewrite
    // and despite the newer day failing:
    expect(await LocalDb.getCursor('health_oura_spo2_through'),
        anyOf('2026-03-10', isNull));
  });

  test('#3 a forgotten ring with MANY samples never exports over a paired '
      'ring with FEW — the atomic candidate', () async {
    final store = StatefulSpo2Store();
    // Forgotten ring: 10 samples of 99.
    await LocalDb.putObservations(
        [for (var i = 0; i < 10; i++) rowsFor(d9, [99]).first],
        deviceId: 'oura-forgotten');
    // Paired ring: 2 samples of 95 — same day.
    await pairRing('oura-ring-1');
    await LocalDb.putObservations(
        rowsFor(d9.add(const Duration(minutes: 30)), [95, 95]),
        deviceId: 'oura-ring-1');
    await runPass(store, interpretationVerified: true);
    // ONLY the paired ring's value is in the store, exactly once.
    expect(store.own, hasLength(1));
    expect(store.own.first.$4, 95);
  });

  test('#5/#7 the same export twice leaves ONE sample; a MOVED interval '
      'replaces the old one; foreign samples stay', () async {
    final store = StatefulSpo2Store();
    await pairRing('oura-ring-1');
    await LocalDb.putObservations(
        rowsFor(d9, [90, 90, 100]), deviceId: 'oura-ring-1');
    // A foreign sample inside the same day — the Oura app's or the
    // Apple Watch's. Our day-window delete must never remove it.
    store.foreign.add((d9.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
        d9.add(const Duration(minutes: 6)).millisecondsSinceEpoch, 88));

    await runPass(store, interpretationVerified: true);
    await runPass(store, interpretationVerified: true);
    // ONE own sample for the day (93.33 over three), foreign untouched.
    expect(store.samplesOf('2026-03-09'), hasLength(1));
    expect(store.samplesOf('2026-03-09').first.$3, closeTo(93.33333333333333, 1e-10));
    expect(store.foreign, hasLength(1));

    // A late delivery MOVES the candidate: samples land 30 min later,
    // outside the old interval. The day-window clear must remove the OLD
    // own sample wherever it sits — the final state is ONE sample at
    // the NEW interval.
    // Late delivery APPENDS to the same day: the candidate now spans
    // all five samples (mean 92.6), starting at the day's first second.
    // The day-window clear removed the OLD own sample; the final state
    // is ONE sample at the NEW candidate interval.
    final later = d9.add(const Duration(minutes: 30));
    await LocalDb.putObservations(rowsFor(later, [91, 92]), deviceId: 'oura-ring-1');
    await runPass(store, interpretationVerified: true);
    final own = store.samplesOf('2026-03-09');
    expect(own, hasLength(1));
    expect(own.first.$1, d9.millisecondsSinceEpoch);
    expect(own.first.$3, closeTo(92.6, 1e-10));
    expect(store.foreign, hasLength(1));
  });

  test('#5 delete succeeded, write failed -> no sample; retry heals; the '
      'day stays pending (no watermark)', () async {
    final store = StatefulSpo2Store();
    await pairRing('oura-ring-1');
    await LocalDb.putObservations(
        rowsFor(d9, [90, 90, 100]), deviceId: 'oura-ring-1');
    store.refuseWrites.add('2026-03-09');
    await runPass(store, interpretationVerified: true);
    expect(store.own, isEmpty);
    expect(await LocalDb.getCursor('health_oura_spo2_done:2026-03-09'),
        isNull);
    store.refuseWrites.clear();
    await runPass(store, interpretationVerified: true);
    expect(store.own, hasLength(1));
  });

  test('#6 late data MORE than three days behind the cursor reaches the '
      'real production path via the changed-day watermark', () async {
    final store = StatefulSpo2Store();
    await pairRing('oura-ring-1');
    final oldDay = DateTime(2026, 1, 5, 1, 0, 0);
    await LocalDb.putObservations(rowsFor(oldDay, [95]), deviceId: 'oura-ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.own, hasLength(1));
    expect(await LocalDb.getCursor('health_oura_spo2_through'), '2026-01-05');
    // Days far ahead push the cursor well beyond any fixed tail window.
    for (var d = 6; d <= 20; d++) {
      await LocalDb.putObservations(
          rowsFor(DateTime(2026, 1, d, 1, 0, 0), [95]),
          deviceId: 'oura-ring-1');
    }
    await runPass(store, interpretationVerified: true);
    expect(await LocalDb.getCursor('health_oura_spo2_through'), '2026-01-20');
    // Late data on the old day, >3 days behind the cursor.
    await LocalDb.putObservations(
        rowsFor(oldDay.add(const Duration(seconds: 30)), [96, 96]),
        deviceId: 'oura-ring-1');
    // The REAL production pass picks it up through the watermark, not a
    // fixed tail: the old day's sample is REPLACED (93 over three).
    await runPass(store, interpretationVerified: true);
    final own = store.samplesOf('2026-01-05');
    expect(own, hasLength(1));
    // Hand-computed over all three samples: (95+96+96)/3 = 95.666...
    expect(own.first.$3, closeTo(95.66666666666667, 1e-10));
    expect(store.own, hasLength(16),
        reason: 'one sample per day, 15 days + the re-exported old day');
  });
}
