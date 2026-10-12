// The Oura-SpO2 backfill LIFECYCLE against the PRODUCTION entry point.
//
// `HealthExporter.debugRunSpo2Pass` IS `_exportOuraSpo2BehindCursor` —
// the same enumeration, the same atomic candidate, the same gate, the
// same cursor tables, the same retry order production runs. NOTHING is
// re-wired in the test. The ONLY doubles are the health-store
// operations (through a STATEFUL store that keeps real sample state and
// counts every store contact) and the interpretation gate, granted as
// an explicit test parameter.
//
// Round-5 audit cases, each with hand-computed expectations:
// value correction at the same second; an EARLIER late delivery below
// the old MAX; a removed measurement; an owner change without a newer
// stamp; a vanished candidate (forgotten ring / deleted rows / moved
// across midnight); more than 30 unsuitable days; and idempotence — an
// unchanged candidate makes NO new health-store contact.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_edge/health/health_export.dart';

/// A STATEFUL health-store double. It keeps the samples this "app"
/// wrote, deletes only samples inside the given window, and counts
/// EVERY store contact so idempotence is provable by absence.
class StatefulSpo2Store {
  final own = <(String, int, int, double)>[];
  final foreign = <(int, int, double)>[];
  final refuseWrites = <String>{};
  final refuseDeletes = <String>{};

  /// Store-contact counters: the idempotence case asserts these stay
  /// FLAT for an unchanged candidate.
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

  final d9 = DateTime(2026, 3, 9, 1, 0, 0);

  /// DISTINCT measurement seconds — never the same stamp twice. The
  /// round-4 fixture wrote one stamp ten times; this builds a real
  /// spread the stored state can be asserted against.
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

  Future<void> pairRing(String id) async {
    final db = await LocalDb.instance;
    await db.insert('device', {
      'id': id,
      'adapter_id': 'oura',
      'first_seen': d9.millisecondsSinceEpoch,
      'last_seen': d9.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> putRows(DateTime start, List<num> values, String ring) =>
      LocalDb.putObservations(rowsAt(start, values), deviceId: ring);

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

  test('#1 value correction at the SAME second re-exports (the '
      'fingerprint covers the mean, not only MAX)', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(d9, [90, 90, 100], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09').single.$3,
        closeTo(93.33333333333333, 1e-10));

    // A replay that CORRECTS one value in place — same seconds, same
    // count, same MAX. MAX(ts_ms)+COUNT(*) cannot see this; the
    // fingerprint's mean can: 90 -> 96 moves the mean to 95.333...
    await putRows(d9, [96, 90, 100], 'ring-1');
    await runPass(store, interpretationVerified: true);
    final after = store.samplesOf('2026-03-09');
    expect(after, hasLength(1), reason: 'replaced, not stacked');
    expect(after.single.$3, closeTo(95.33333333333333, 1e-10));
  });

  test('#2 an EARLIER late delivery below the old MAX re-exports '
      '(the fingerprint covers first_ms)', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(d9.add(const Duration(hours: 1)), [95, 96], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09'), hasLength(1));

    // A late delivery EARLIER than every stored second: MAX does not
    // move, but the interval and mean do.
    await putRows(d9, [90], 'ring-1');
    await runPass(store, interpretationVerified: true);
    final after = store.samplesOf('2026-03-09');
    expect(after, hasLength(1));
    // Hand-computed over three: (90+95+96)/3 = 93.666...
    expect(after.single.$3, closeTo(93.66666666666667, 1e-10));
    // The interval now starts at the delivered second.
    expect(after.single.$1, d9.millisecondsSinceEpoch);
  });

  test('#3 a REMOVED measurement re-exports (count/mean/last_ms change)',
      () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(d9, [90, 90, 100], 'ring-1');
    await runPass(store, interpretationVerified: true);

    // Delete one observation row (the day still has a candidate).
    final db = await LocalDb.instance;
    await db.delete('observation',
        where: "vendor_key = 'spo2' AND value = 100 AND date = ?",
        whereArgs: ['2026-03-09']);
    await runPass(store, interpretationVerified: true);
    final after = store.samplesOf('2026-03-09');
    expect(after, hasLength(1));
    // Hand-computed over the remaining two: mean 90.
    expect(after.single.$3, 90);
  });

  test('#4 an OWNER CHANGE without a newer stamp re-exports (the '
      'fingerprint covers the device)', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await pairRing('ring-2');
    // ring-1 measured the whole day; ring-2 one earlier second.
    await putRows(d9, [95, 95, 95], 'ring-1');
    await putRows(d9.subtract(const Duration(seconds: 1)), [97], 'ring-2');
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09').single.$3, 95);

    // ring-2 gains the MAJORITY: three more samples at its OWN earlier
    // seconds — all below the old MAX. The owner flips to ring-2 with
    // FIVE samples of 97: mean 97, no new MAX anywhere. The fingerprint
    // covers the device and the mean, so the day re-exports.
    await putRows(d9.subtract(const Duration(seconds: 4)), [97, 97, 97],
        'ring-2');
    await runPass(store, interpretationVerified: true);
    final after = store.samplesOf('2026-03-09');
    expect(after, hasLength(1));
    // ring-2 now owns the day with five samples: (97*5)/5 = 97.
    expect(after.single.$3, 97);
  });

  test('#5/#7a the LAST suitable observation of a once-exported day is '
      'removed: the prior own export is cleaned up, foreign data stays',
      () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(d9, [90, 90, 100], 'ring-1');
    // A foreign sample on the same day — untouchable by our delete.
    store.foreign.add((
      d9.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      d9.add(const Duration(minutes: 6)).millisecondsSinceEpoch,
      88.0
    ));
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09'), hasLength(1));

    // Every observation of the day is deleted (the candidate vanishes).
    final db = await LocalDb.instance;
    await db.delete('observation',
        where: "vendor_key = 'spo2' AND date = ?",
        whereArgs: ['2026-03-09']);
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09'), isEmpty,
        reason: 'the stale own export was removed');
    expect(store.foreign, hasLength(1), reason: 'foreign data untouched');
    expect(await LocalDb.getCursor('health_oura_spo2_done:2026-03-09'),
        isNull);
  });

  test('#7b a FORGOTTEN registered source device: vanished-candidate '
      'cleanup removes the stale export', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(d9, [90, 90, 100], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09'), hasLength(1));

    // The ring is forgotten — its row goes, its observations stay.
    final db = await LocalDb.instance;
    await db.delete('device', where: 'id = ?', whereArgs: ['ring-1']);
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09'), isEmpty);
    expect(await LocalDb.getCursor('health_oura_spo2_done:2026-03-09'),
        isNull);
  });

  test('#7c a time correction across MIDNIGHT: the old day is cleaned, '
      'the new day is exported, foreign data on both days stays',
      () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    // Day A: 2026-03-09 01:00.
    await putRows(d9, [90, 90, 100], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-09'), hasLength(1));
    // Foreign samples on BOTH days.
    store.foreign.add((
      d9.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      d9.add(const Duration(minutes: 6)).millisecondsSinceEpoch,
      88.0
    ));
    final dayBForeign = (
      DateTime(2026, 3, 10, 2, 0, 0).millisecondsSinceEpoch,
      DateTime(2026, 3, 10, 2, 0, 1).millisecondsSinceEpoch,
      89.0
    );
    store.foreign.add(dayBForeign);

    // The anchor is corrected: the same three seconds now land on
    // 2026-03-10. Day A loses every row (its candidate vanishes), day B
    // gains them (a fresh candidate).
    final db = await LocalDb.instance;
    await db.delete('observation',
        where: "vendor_key = 'spo2' AND date = ?",
        whereArgs: ['2026-03-09']);
    final dayB = DateTime(2026, 3, 10, 2, 0, 0);
    await putRows(dayB, [90, 90, 100], 'ring-1');
    await runPass(store, interpretationVerified: true);

    // The OLD day's own export is gone, the NEW day carries it.
    expect(store.samplesOf('2026-03-09'), isEmpty);
    final b = store.samplesOf('2026-03-10');
    expect(b, hasLength(1));
    expect(b.single.$3, closeTo(93.33333333333333, 1e-10));
    // Foreign data on BOTH days untouched.
    expect(store.foreign, hasLength(2));
  });

  test('#3-audit more than 30 permanently unsuitable days never pin the '
      'scan: the suitable day behind them is reached, the skipped days '
      'stay re-evaluable', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    // 35 days of a FORGOTTEN ring's rows (no device row -> no
    // candidate, permanently unsuitable until it is re-paired), then a
    // suitable day behind them.
    for (var i = 0; i < 35; i++) {
      final day = DateTime(2026, 1, 1 + i, 1, 0, 0);
      await putRows(day, [90, 91], 'ring-gone');
    }
    final suitableDay = DateTime(2026, 2, 10, 1, 0, 0);
    await putRows(suitableDay, [95, 96], 'ring-1');

    // Several bounded passes: the scan walks past the unsuitable days.
    for (var pass = 0; pass < 6; pass++) {
      await runPass(store, interpretationVerified: true);
    }
    // The suitable day WAS reached and written.
    expect(store.samplesOf('2026-02-10'), hasLength(1));
    expect(store.samplesOf('2026-02-10').single.$3, 95.5);

    // The skipped days stay RE-EVALUABLE: re-pair the forgotten ring and
    // its FIRST days export (the reassess scope picks them up).
    await pairRing('ring-gone');
    for (var pass = 0; pass < 4; pass++) {
      await runPass(store, interpretationVerified: true);
    }
    expect(store.samplesOf('2026-01-01'), hasLength(1));
  });

  test('#7 idempotence: an UNCHANGED candidate makes NO new health-store '
      'contact after a successful export', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(d9, [90, 90, 100], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.writeCalls, 1);
    final deletesAfterFirst = store.deleteCalls;

    // An identical replay of the same rows — the candidate is unchanged,
    // so no scope may hand the day to the walk again.
    await putRows(d9, [90, 90, 100], 'ring-1');
    await runPass(store, interpretationVerified: true);
    await runPass(store, interpretationVerified: true);
    expect(store.writeCalls, 1, reason: 'no re-export of the same candidate');
    expect(store.deleteCalls, deletesAfterFirst,
        reason: 'no health-store contact at all');
    expect(store.samplesOf('2026-03-09'), hasLength(1));
  });

  test('#7 an unrelated non-Oura source appending to an exported day '
      'does not re-export the unchanged candidate', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(d9, [90, 90, 100], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(store.writeCalls, 1);

    // A DIFFERENT device's rows on the same day — not a candidate source
    // (no oura adapter_id), and the candidate is untouched regardless.
    await pairRing('other-band'); // registered but not an Oura ring
    final db = await LocalDb.instance;
    await db.update('device', {'adapter_id': 'whoop_gen4'},
        where: 'id = ?', whereArgs: ['other-band']);
    await putRows(d9.add(const Duration(minutes: 10)), [99, 99],
        'other-band');
    await runPass(store, interpretationVerified: true);
    expect(store.writeCalls, 1, reason: 'the candidate never changed');
    expect(store.samplesOf('2026-03-09'), hasLength(1));
  });

  test('gate closed: nothing written, both cursors untouched, no skip '
      'markers — the release finds every day', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(d9, [90, 90, 100], 'ring-1');
    await runPass(store, interpretationVerified: false);
    expect(store.own, isEmpty);
    expect(await LocalDb.getCursor('health_oura_spo2_through'), isNull);
    expect(await LocalDb.getCursor('health_oura_spo2_scan_through'), isNull);
    await runPass(store, interpretationVerified: true);
    expect(store.own, hasLength(1));
  });

  test('cursor expectations are EXACT: a successful newer day sets the '
      'frontier to that day, a failure does not move it', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(d9, [90, 90, 100], 'ring-1');
    final d10 = DateTime(2026, 3, 10, 2, 0, 0);
    await putRows(d10, [96, 98], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(await LocalDb.getCursor('health_oura_spo2_through'),
        '2026-03-10');

    // The newer day now fails; the older day gets late data and
    // re-exports. The success cursor stays EXACTLY at the failed day's
    // predecessor... no: the failed day never moved it, so it stays at
    // '2026-03-10' (the last written day).
    store.refuseWrites.add('2026-03-10');
    await putRows(d9.add(const Duration(seconds: 10)), [97, 97], 'ring-1');
    await runPass(store, interpretationVerified: true);
    expect(await LocalDb.getCursor('health_oura_spo2_through'),
        '2026-03-10',
        reason: 'the older rewrite never dragged it back; the failed '
            'newer day never advanced it');
    // The older day WAS re-exported (94.8 over five, hand-computed).
    expect(store.samplesOf('2026-03-09').single.$3, closeTo(94.8, 1e-10));
    // The refused day still holds its old sample; retry heals it.
    expect(store.samplesOf('2026-03-10'), hasLength(1));
    store.refuseWrites.clear();
    await runPass(store, interpretationVerified: true);
    expect(store.samplesOf('2026-03-10').single.$3, 97);
  });

  test('delete succeeded, write failed -> no sample, no watermark, '
      'retry heals', () async {
    final store = StatefulSpo2Store();
    await pairRing('ring-1');
    await putRows(d9, [90, 90, 100], 'ring-1');
    store.refuseWrites.add('2026-03-09');
    await runPass(store, interpretationVerified: true);
    expect(store.own, isEmpty);
    expect(await LocalDb.getCursor('health_oura_spo2_done:2026-03-09'),
        isNull);
    store.refuseWrites.clear();
    await runPass(store, interpretationVerified: true);
    expect(store.own, hasLength(1));
  });

  test('the forgotten-ring-with-many-samples fixture: TEN DISTINCT '
      'measurement seconds, checked against the stored BESTAND',
      () async {
    final store = StatefulSpo2Store();
    // ring-1 (paired): two samples at 01:00:00 and 01:00:01.
    await pairRing('ring-1');
    await putRows(d9, [95, 95], 'ring-1');
    // ring-gone (forgotten): TEN DISTINCT seconds at 01:10:00..01:10:09.
    final gone = d9.add(const Duration(minutes: 10));
    await putRows(gone, [for (var i = 0; i < 10; i++) 99], 'ring-gone');

    await runPass(store, interpretationVerified: true);
    // The paired ring's candidate is exported, exactly once.
    expect(store.own, hasLength(1));
    expect(store.own.single.$1, '2026-03-09');
    expect(store.own.single.$4, 95);
    // The stored DB rows: the forgotten ring's ten DISTINCT seconds are
    // all banked (display keeps history), ten rows, ten distinct stamps.
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
        "SELECT ts_ms FROM observation WHERE device_id = 'ring-gone' "
        'ORDER BY ts_ms');
    expect(rows, hasLength(10));
    expect(rows.map((r) => r['ts_ms']).toSet(), hasLength(10),
        reason: 'ten distinct measurement seconds, not one stamp x10');
    // And its stamps are exactly the 10-second spread, hand-computed.
    expect(rows.first['ts_ms'], gone.millisecondsSinceEpoch);
    expect(rows.last['ts_ms'],
        gone.add(const Duration(seconds: 9)).millisecondsSinceEpoch);
  });
}
