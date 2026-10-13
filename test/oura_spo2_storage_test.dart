// The Oura SpO2 storage path: per-second observation rows land, replays
// collapse on the identity index, and the day summary is the
// equal-weighted mean of ALL stored samples — computed by SQL over rows,
// independent of every batch boundary.
//
// Expectations are INDEPENDENT: means hand-computed from the fixtures.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/observation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'oura_spo2_storage_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
  });
  tearDown(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  // 2026-03-09 01:00:00 local (a fixed wall clock, so the day label is the
  // local calendar day via Observation's own dayLabelOf).
  final night = DateTime(2026, 3, 9, 1, 0, 0);

  Observation row(
    DateTime at,
    num value, {
    String vendorKey = 'spo2',
    String? key,
    String unit = '%',
    ObservationSource kind = ObservationSource.vendor,
    String attribution = 'Oura',
  }) =>
      Observation(
        at: at,
        sourceKind: kind,
        vendorKey: key == null ? vendorKey : null,
        key: key,
        value: value,
        unit: unit,
        attribution: attribution,
      );

  test('day summary is the mean over all stored samples, with the count',
      () async {
    await LocalDb.putObservations([
      row(night, 90),
      row(night.add(const Duration(seconds: 1)), 90),
      row(night.add(const Duration(seconds: 2)), 100),
    ]);
    final s = await LocalDb.ouraSpo2DaySummary('2026-03-09');
    expect(s, isNotNull);
    expect(s!.count, 3);
    expect(s.meanPercent, closeTo(93.33333333333333, 1e-10));
    expect(s.firstTsMs, night.millisecondsSinceEpoch);
    expect(s.lastTsMs,
        night.add(const Duration(seconds: 2)).millisecondsSinceEpoch);
  });

  test('a re-imported identical batch replaces, never duplicates', () async {
    final rows = [
      row(night, 96),
      row(night.add(const Duration(seconds: 1)), 98),
      row(night.add(const Duration(seconds: 2)), 97),
    ];
    await LocalDb.putObservations(rows, deviceId: 'oura-ring-1');
    // The replay: same seconds, same values — what a re-read delivers.
    await LocalDb.putObservations(rows, deviceId: 'oura-ring-1');
    final s = await LocalDb.ouraSpo2DaySummary('2026-03-09');
    expect(s!.count, 3);
    expect(s.meanPercent, 97.0);
  });

  test('two rings on one day never blend — per-device summaries, '
      'most samples owns the day', () async {
    await LocalDb.putObservations([
      row(night, 90),
      row(night.add(const Duration(seconds: 1)), 90),
    ], deviceId: 'oura-ring-1');
    await LocalDb.putObservations([
      row(night.add(const Duration(seconds: 2)), 100),
    ], deviceId: 'oura-ring-2');
    final perDevice = await LocalDb.ouraSpo2DaySummaries('2026-03-09');
    expect(perDevice.keys, ['oura-ring-1', 'oura-ring-2']);
    // Hand-computed: each ring's own mean over its OWN samples only.
    expect(perDevice['oura-ring-1']!.meanPercent, 90);
    expect(perDevice['oura-ring-1']!.count, 2);
    expect(perDevice['oura-ring-2']!.meanPercent, 100);
    expect(perDevice['oura-ring-2']!.count, 1);
    // The one-number reader takes the OWNER (most samples), never a blend:
    // the blend would be 93.33 and is pinned as NOT the answer.
    final s = await LocalDb.ouraSpo2DaySummary('2026-03-09');
    expect(s!.meanPercent, 90);
    expect(s.count, 2);
  });

  test('a ring syncing LATE does not displace the day owner by freshness',
      () async {
    // ring-1 measured the whole night; ring-2 syncs three fresher seconds a
    // week later. Owner stays the ring that measured the day.
    await LocalDb.putObservations([
      for (var i = 0; i < 10; i++)
        row(night.add(Duration(seconds: i)), 95),
    ], deviceId: 'oura-ring-1');
    await LocalDb.putObservations([
      row(night.add(const Duration(seconds: 20)), 99),
      row(night.add(const Duration(seconds: 21)), 99),
      row(night.add(const Duration(seconds: 22)), 99),
    ], deviceId: 'oura-ring-2');
    final s = await LocalDb.ouraSpo2DaySummary('2026-03-09');
    expect(s!.meanPercent, 95);
    expect(s.count, 10);
  });

  test('#3 the atomic candidate: a forgotten ring with MANY samples never '
      'ranks over a paired ring with FEW', () async {
    final db = await LocalDb.instance;
    // The PAIRED ring (adapter_id as OuraLink writes it), few samples.
    await db.insert('device', {
      'id': 'oura-paired',
      'adapter_id': 'oura',
      'first_seen': night.millisecondsSinceEpoch,
      'last_seen': night.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await LocalDb.putObservations(
        [row(night, 95), row(night.add(const Duration(seconds: 1)), 95)],
        deviceId: 'oura-paired');
    // The FORGOTTEN ring: ten samples of 99, no device row.
    await LocalDb.putObservations(
        [for (var i = 0; i < 10; i++) row(night.add(Duration(seconds: i + 10)), 99)],
        deviceId: 'oura-forgotten');
    // The candidate is the PAIRED ring's value — never the forgotten
    // ring's, however many samples it has.
    final c = await LocalDb.ouraSpo2DayCandidate('2026-03-09');
    expect(c, isNotNull);
    expect(c!.deviceId, 'oura-paired');
    expect(c.meanPercent, 95);
    // Display keeps the forgotten ring's history banked.
    expect((await LocalDb.ouraSpo2DaySummary('2026-03-09')), isNotNull);
  });

  test('a device row WITHOUT the oura adapter_id never ranks — the unique '
      'Oura data-path filter', () async {
    final db = await LocalDb.instance;
    // A paired device of ANOTHER family carrying spo2-keyed rows.
    await db.insert('device', {
      'id': 'other-band',
      'adapter_id': 'whoop_gen4',
      'first_seen': night.millisecondsSinceEpoch,
      'last_seen': night.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await LocalDb.putObservations(
        [row(night, 91), row(night.add(const Duration(seconds: 1)), 91)],
        deviceId: 'other-band');
    // Registered, paired — but not an Oura ring: no candidate.
    expect(await LocalDb.ouraSpo2DayCandidate('2026-03-09'), isNull);
  });

  test('the day owner among paired Oura rings is the one with the most '
      'samples (deterministic tie-break)', () async {
    final db = await LocalDb.instance;
    for (final id in ['oura-ring-1', 'oura-ring-2']) {
      await db.insert('device', {
        'id': id,
        'adapter_id': 'oura',
        'first_seen': night.millisecondsSinceEpoch,
        'last_seen': night.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await LocalDb.putObservations([
      row(night, 90),
      row(night.add(const Duration(seconds: 1)), 90),
    ], deviceId: 'oura-ring-1');
    await LocalDb.putObservations([
      row(night.add(const Duration(seconds: 2)), 100),
    ], deviceId: 'oura-ring-2');
    final c = await LocalDb.ouraSpo2DayCandidate('2026-03-09');
    expect(c!.deviceId, 'oura-ring-1');
  });

  test('unsuitable rows are outside the summary: wrong unit, wrong kind, '
      'wrong key, out of floor', () async {
    await LocalDb.putObservations([
      // The WHOOP import's row — OUR vocabulary, not the ring's.
      row(night, 88, key: 'spo2'),
    ]);
    await LocalDb.putObservations([
      row(night.add(const Duration(seconds: 1)), 95, unit: 'raw'),
      row(night.add(const Duration(seconds: 2)), 95, kind: ObservationSource.entered),
      row(night.add(const Duration(seconds: 3)), 69),
      row(night.add(const Duration(seconds: 4)), 101),
      row(night.add(const Duration(seconds: 5)), 95, vendorKey: 'BioCharge'),
    ]);
    final s = await LocalDb.ouraSpo2DaySummary('2026-03-09');
    expect(s, isNull);
  });

  test('restore/import marks the merged Oura-SpO2 days dirty (the '
      'page-txn hook)', () async {
    List<Observation> mk(DateTime s, List<num> v) => [
          for (var i = 0; i < v.length; i++)
            Observation(
              at: s.add(Duration(seconds: i)),
              sourceKind: ObservationSource.vendor,
              vendorKey: 'spo2',
              value: v[i],
              unit: '%',
              attribution: 'Oura',
            ),
        ];
    final day = DateTime.now().subtract(const Duration(days: 3));
    await LocalDb.putObservations(mk(day, [95, 96]), deviceId: 'r-merge');
    // Drain the dirty set (a completed pass).
    for (final d in await LocalDb.ouraSpo2DirtyDays(limit: 100)) {
      await LocalDb.clearOuraSpo2DirtyIfUnchanged(d.date, d.token);
    }
    expect(await LocalDb.ouraSpo2DirtyDays(), isEmpty);
    // A backup file with ONE changed row for the same day.
    final dir = await databaseFactory.getDatabasesPath();
    final srcPath = p.join(dir, 'merge_src_test.db');
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
        'CREATE TABLE observation (device_id TEXT NOT NULL DEFAULT "", '
        'ts_ms INTEGER NOT NULL, date TEXT NOT NULL, '
        'source_kind TEXT NOT NULL, vendor_key TEXT, key TEXT, '
        'value REAL, unit TEXT, attribution TEXT NOT NULL, '
        'CHECK (vendor_key IS NOT NULL OR key IS NOT NULL))');
    final at = day.add(const Duration(seconds: 5));
    final m = at.month.toString().padLeft(2, '0');
    final dd = at.day.toString().padLeft(2, '0');
    final label = '${at.year}-$m-$dd';
    await src.insert('observation', {
      'device_id': 'r-merge',
      'ts_ms': at.millisecondsSinceEpoch,
      'date': label,
      'source_kind': 'vendor',
      'vendor_key': 'spo2',
      'value': 97.0,
      'unit': '%',
      'attribution': 'Oura',
    });
    final counts = await LocalDb.importFromDbFile(srcPath);
    expect(counts['observation'], greaterThan(0));
    // The merged day IS dirty again — the hook marked it inside the
    // merge's own page transaction.
    final dirty = await LocalDb.ouraSpo2DirtyDays();
    expect(dirty.map((d) => d.date), contains(label));
    await src.close();
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('an empty day has no summary', () async {
    expect(await LocalDb.ouraSpo2DaySummary('2026-03-09'), isNull);
  });

  test('a night over midnight contributes to its own local days', () async {
    // 23:50 on Mar 8 to 00:10 on Mar 9 — the seconds before midnight land on
    // the 8th, the ones after on the 9th, via dayLabelOf (the DST-aware
    // helper), never a ±86400 arithmetic.
    await LocalDb.putObservations([
      row(DateTime(2026, 3, 8, 23, 50), 96),
      row(DateTime(2026, 3, 8, 23, 59, 59), 97),
      row(DateTime(2026, 3, 9, 0, 0), 98),
      row(DateTime(2026, 3, 9, 0, 10), 99),
    ]);
    final s8 = await LocalDb.ouraSpo2DaySummary('2026-03-08');
    final s9 = await LocalDb.ouraSpo2DaySummary('2026-03-09');
    expect(s8!.count, 2);
    expect(s8.meanPercent, 96.5);
    expect(s9!.count, 2);
    expect(s9.meanPercent, 98.5);
  });
}
