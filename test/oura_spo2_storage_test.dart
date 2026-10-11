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

  test('the day owner is null when the owning ring was forgotten', () async {
    await LocalDb.putObservations([
      row(night, 96),
    ], deviceId: 'oura-gone');
    // No `device` row for 'oura-gone' — the ring was forgotten.
    expect(await LocalDb.ouraSpo2DayDevice('2026-03-09'), isNull);
    // The rows stay banked (the summary still reads them — display keeps
    // history), but the export's device gate sees null.
    expect((await LocalDb.ouraSpo2DaySummary('2026-03-09')), isNotNull);
  });

  test('the day owner is the still-paired ring with the most samples',
      () async {
    // Both rings have device rows; the summary's owner is ring-1 (most
    // samples) — and only a JOINed row counts.
    final db = await LocalDb.instance;
    for (final id in ['oura-ring-1', 'oura-ring-2']) {
      await db.insert('device', {
        'id': id,
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
    expect(await LocalDb.ouraSpo2DayDevice('2026-03-09'), 'oura-ring-1');
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
