// Model-based testing for the Oura-SpO₂ export pipeline: an independent
// expectation model (plain loops, no SQL, no production helpers) driven by
// 400 seeded random operation sequences, verified against the REAL
// production pass over the REAL database.
//
// Invariants checked after convergence (healthy store, clock beyond the
// largest backoff):
//  I1 per day with a candidate: exactly ONE own sample; value = mean,
//     interval = first..last measured stamp, source = the ring with the
//     most samples (tie: smallest device_id).
//  I2 days without a candidate: no own sample.
//  I3 foreign samples survive untouched.
//  I4 no write call ever carries a value outside (0, 100].
//  I5 a further pass at rest makes NO store contact.
//  I6 convergence within ceil(openDays / 30) + 3 passes.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/data/observation.dart';

String _label(DateTime d) {
  final m = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  return '${d.year}-$m-$dd';
}

typedef Expected = ({String ring, double mean, int n, int first, int last});

/// The independent model: plain maps and loops. REPLACE on identical
/// identity (ring + ts), exactly like the observation table's index.
class Model {
  final obs = <String, Map<int, double>>{}; // ring -> tsMs -> percent
  final paired = <String>{};

  void put(String ring, int tsMs, double v) =>
      (obs[ring] ??= {})[tsMs] = v;

  void deleteDay(String day) {
    for (final m in obs.values) {
      m.removeWhere(
          (ts, _) => _label(DateTime.fromMillisecondsSinceEpoch(ts)) == day);
    }
  }

  Map<String, Expected> expected() {
    final perDay = <String, Map<String, List<(int, double)>>>{};
    obs.forEach((ring, rows) {
      if (!paired.contains(ring)) return;
      rows.forEach((ts, v) {
        if (v < 70 || v > 100) return;
        final day = _label(DateTime.fromMillisecondsSinceEpoch(ts));
        ((perDay[day] ??= {})[ring] ??= []).add((ts, v));
      });
    });
    final out = <String, Expected>{};
    perDay.forEach((day, byRing) {
      // most samples wins; tie -> smallest device_id (the candidate query's
      // ORDER BY n DESC, device_id ASC LIMIT 1).
      final rings = byRing.keys.toList()
        ..sort((a, b) {
          final c = byRing[b]!.length.compareTo(byRing[a]!.length);
          return c != 0 ? c : a.compareTo(b);
        });
      final r = rings.first;
      final rows = byRing[r]!;
      var sum = 0.0;
      var lo = rows.first.$1, hi = rows.first.$1;
      for (final e in rows) {
        sum += e.$2;
        lo = min(lo, e.$1);
        hi = max(hi, e.$1);
      }
      out[day] = (ring: r, mean: sum / rows.length, n: rows.length,
          first: lo, last: hi);
    });
    return out;
  }
}

/// I7: every done marker WITHOUT an in-flight marker must correspond to
/// exactly ONE own sample in the store (the marker is sample proof).
Future<void> _expectMarkerImpliesSample(_Store store, String reason) async {
  final db = await LocalDb.instance;
  final p = kOuraSpo2DonePrefix;
  final rows = await db.rawQuery(
    'SELECT substr(name, ?) AS day FROM sync_cursor '
    'WHERE substr(name, 1, ?) = ?',
    [p.length + 1, p.length, p],
  );
  for (final r in rows) {
    final day = r['day'] as String;
    final inflight =
        await LocalDb.getCursor('$kOuraSpo2InflightPrefix$day');
    if (inflight != null) continue;
    expect(store.samplesOf(day), hasLength(1),
        reason: 'I7: marker without sample on $day\n$reason');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'oura_spo2_model_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  /// Same state as a fresh database: the tables are emptied inside one
  /// transaction. The primary device row survives (it is not a ring).
  Future<void> resetDb() async {
    final db = await LocalDb.instance;
    await db.transaction((t) async {
      await t.delete('observation');
      await t.delete('device',
          where: "id != ?", whereArgs: [LocalDb.kPrimaryDeviceId]);
      await t.delete('sync_cursor');
    });
  }

  final rings = ['ring-a', 'ring-b', 'ring-c'];

  List<Observation> rowsFor(DateTime start, List<num> vals) => [
        for (var i = 0; i < vals.length; i++)
          Observation(
            at: start.add(Duration(seconds: i)),
            sourceKind: ObservationSource.vendor,
            vendorKey: 'spo2',
            value: vals[i],
            unit: '%',
            attribution: 'Oura',
          ),
      ];

  Future<void> runPassHelper(
    _Store store, {
    required bool interpretationVerified,
    int Function()? nowMs,
  }) =>
      _DbPassRunner.run(store,
          interpretationVerified: interpretationVerified, nowMs: nowMs);

  for (var seed = 1; seed <= 400; seed++) {
    test('model-based, seed $seed', () async {
      await resetDb();
      final rnd = Random(seed);
      final model = Model();
      final store = _Store();
      final log = <String>[];
      final base = DateTime.now();
      var clock = base.millisecondsSinceEpoch;
      // Only the last 10 local days: raw deletes outside the hooks are
      // caught by the 14-day sweep, which is the documented contract.
      DateTime dayAt(int back) => DateTime(base.year, base.month, base.day - back, 1);

      // Foreign samples that must never be touched (I3).
      for (var back = 1; back <= 10; back++) {
        final t = dayAt(back).add(const Duration(minutes: 5));
        store.foreign.add((t.millisecondsSinceEpoch,
            t.add(const Duration(minutes: 1)).millisecondsSinceEpoch, 88.0));
      }
      final foreignBefore = List.of(store.foreign);

      for (var step = 0; step < 80; step++) {
        final op = rnd.nextInt(16);
        final ring = rings[rnd.nextInt(rings.length)];
        final back = 1 + rnd.nextInt(10);
        switch (op) {
          case 0:
          case 1:
          case 2:
          case 3:
            {
              final start =
                  dayAt(back).add(Duration(seconds: rnd.nextInt(30)));
              final n = 1 + rnd.nextInt(5);
              final vals = [for (var i = 0; i < n; i++) 60 + rnd.nextInt(45)];
              log.add('put $ring back=$back vals=$vals');
              await LocalDb.putObservations(rowsFor(start, vals),
                  deviceId: ring);
              for (var i = 0; i < n; i++) {
                model.put(ring,
                    start.add(Duration(seconds: i)).millisecondsSinceEpoch,
                    vals[i].toDouble());
              }
              break;
            }
          case 4:
            log.add('pair $ring');
            await LocalDb.upsertDevice(
                id: ring, adapterId: 'oura', remoteId: 'x-$ring');
            model.paired.add(ring);
            break;
          case 5:
            log.add('forget $ring');
            await LocalDb.deleteDevice(ring);
            model.paired.remove(ring);
            break;
          case 6:
            {
              final label = _label(dayAt(back));
              log.add('deleteDay $label');
              final db = await LocalDb.instance;
              await db.delete('observation',
                  where: "vendor_key = 'spo2' AND date = ?",
                  whereArgs: [label]);
              await LocalDb.deleteCursor('health_oura_spo2_recent_sweep');
              model.deleteDay(label);
              break;
            }
          case 7:
            {
              final label = _label(dayAt(back));
              if (rnd.nextBool()) {
                store.refuseWrites.add(label);
              } else {
                store.refuseWrites.clear();
                store.refuseDeletes.clear();
              }
              log.add('storeToggle $label');
              break;
            }
          case 8:
            {
              // The store THROWS instead of returning false — the
              // exception path of the intent log.
              final label = _label(dayAt(back));
              if (rnd.nextBool()) {
                store.throwOnWrite.add(label);
              } else {
                store.throwOnWrite.clear();
                store.throwOnDelete.clear();
              }
              log.add('throwToggle $label');
              break;
            }
          case 9:
            {
              // adapter switch away from oura (then maybe back).
              final away = rnd.nextBool();
              log.add('adapterSwitch $ring ${away ? 'away' : 'back'}');
              await LocalDb.upsertDevice(
                  id: ring,
                  adapterId: away ? 'whoop_gen4' : 'oura',
                  remoteId: 'x-$ring');
              if (away) {
                model.paired.remove(ring);
              } else {
                model.paired.add(ring);
              }
              break;
            }
          case 10:
            {
              // Same-adapter upsert: no dirty change for an already-oura
              // ring — but it also ENDS an earlier switch-away: 'oura'
              // means paired again, so the model must reflect that.
              log.add('samePair $ring');
              await LocalDb.upsertDevice(
                  id: ring, adapterId: 'oura', remoteId: 'x-$ring');
              model.paired.add(ring);
              break;
            }
          case 11:
            {
              // A gate-closed pass between open ones.
              log.add('gateClosedPass');
              await runPassHelper(store, interpretationVerified: false);
              break;
            }
          case 12:
            {
              // RESTORE: a backup db with its own spo2 rows AND foreign
              // done/dirty markers over the real restore path. The
              // markers must be dropped, the rows merged by identity.
              final label = _label(dayAt(back));
              final ts = dayAt(back).millisecondsSinceEpoch;
              final dir = await databaseFactory.getDatabasesPath();
              final srcPath = p.join(dir, 'model_restore_$seed.db');
              await databaseFactory.deleteDatabase(srcPath);
              final src = await databaseFactory.openDatabase(srcPath);
              await src.execute(
                  'CREATE TABLE observation (device_id TEXT NOT NULL DEFAULT '
                  '"", ts_ms INTEGER NOT NULL, date TEXT NOT NULL, '
                  'source_kind TEXT NOT NULL, vendor_key TEXT, key TEXT, '
                  'value REAL, unit TEXT, attribution TEXT NOT NULL, '
                  'CHECK (vendor_key IS NOT NULL OR key IS NOT NULL))');
              await src.insert('observation', {
                'device_id': ring,
                'ts_ms': ts,
                'date': label,
                'source_kind': 'vendor',
                'vendor_key': 'spo2',
                'value': 97.0,
                'unit': '%',
                'attribution': 'Oura',
              });
              await LocalDb.importFromDbFile(srcPath);
              await src.close();
              await databaseFactory.deleteDatabase(srcPath);
              // Model: the backup's row REPLACES by identity (ring+ts).
              model.put(ring, ts, 97.0);
              log.add('restore $ring $label');
              break;
            }
          default:
            clock += rnd.nextInt(90) * 60000 -
                (rnd.nextInt(10) == 0 ? 3600000 : 0);
            log.add('pass @ $clock');
            await runPassHelper(store,
                interpretationVerified: true, nowMs: () => clock);
            // I7 holds after EVERY pass, not only at convergence.
            await _expectMarkerImpliesSample(
                store, 'I7 after pass, seed $seed\n${log.join('\n')}');
        }
      }

      // Heal and converge (I6).
      store.refuseWrites.clear();
      store.refuseDeletes.clear();
      store.throwOnWrite.clear();
      store.throwOnDelete.clear();
      clock += 25 * 3600000; // beyond the largest backoff (1280 min)
      await LocalDb.deleteCursor('health_oura_spo2_recent_sweep');
      var prev = -1;
      for (var pass = 0; pass < 20; pass++) {
        await runPassHelper(store,
            interpretationVerified: true, nowMs: () => clock);
        final now = store.writeCalls * 1000 + store.deleteCalls;
        if (now == prev) break;
        prev = now;
      }
      final contactsAtRest = store.writeCalls * 1000 + store.deleteCalls;
      await runPassHelper(store,
          interpretationVerified: true, nowMs: () => clock);
      expect(store.writeCalls * 1000 + store.deleteCalls, contactsAtRest,
          reason: 'I5: no store contact at rest\nseed $seed\n${log.join('\n')}');

      final exp = model.expected();
      final days = {for (final s in store.own) s.$1};
      for (final day in {...exp.keys, ...days}) {
        final got = store.samplesOf(day);
        final want = exp[day];
        if (want == null) {
          expect(got, isEmpty,
              reason: 'I2 $day\nseed $seed\n${log.join('\n')}');
        } else {
          expect(got, hasLength(1),
              reason: 'I1 $day\nseed $seed\n${log.join('\n')}');
          expect(got.single.$3, closeTo(want.mean, 1e-9),
              reason: 'I1 mean $day\nseed $seed\n${log.join('\n')}');
          expect(got.single.$1, want.first,
              reason: 'I1 first $day\nseed $seed\n${log.join('\n')}');
          expect(got.single.$2, want.last,
              reason: 'I1 last $day\nseed $seed\n${log.join('\n')}');
        }
      }
      expect(store.foreign, foreignBefore,
          reason: 'I3\nseed $seed\n${log.join('\n')}');
    }, timeout: const Timeout(Duration(minutes: 4)));
  }

  test('gate closed: no store contact at all, all days stay dirty',
      () async {
    final store = _Store();
    await LocalDb.upsertDevice(
        id: 'ring-a', adapterId: 'oura', remoteId: 'x');
    final day = DateTime.now().subtract(const Duration(days: 3));
    await LocalDb.putObservations(rowsFor(day, [95, 96]), deviceId: 'ring-a');
    final dirty = await LocalDb.ouraSpo2DirtyDays(limit: 10);
    expect(dirty, isNotEmpty);
    await runPassHelper(store, interpretationVerified: false);
    expect(store.writeCalls, 0);
    expect(store.deleteCalls, 0);
    expect(await LocalDb.ouraSpo2DirtyDays(limit: 10), isNotEmpty,
        reason: 'a closed gate keeps every day dirty');
  });
}

/// A stateful store double with the I4 assertion built in: any write with
/// a value outside (0, 100] or not finite fails the test on the spot.
class _Store {
  final own = <(String, int, int, double)>[];
  final foreign = <(int, int, double)>[];
  final refuseWrites = <String>{};
  final refuseDeletes = <String>{};
  final throwOnWrite = <String>{};
  final throwOnDelete = <String>{};
  int writeCalls = 0;
  int deleteCalls = 0;

  Future<bool> deleteWindow(String day, DateTime start, DateTime end) async {
    deleteCalls++;
    if (throwOnDelete.contains(day)) {
      throw StateError('model store delete exploded on $day');
    }
    if (refuseDeletes.contains(day)) return false;
    final s = start.millisecondsSinceEpoch;
    final e = end.millisecondsSinceEpoch;
    own.removeWhere((x) => x.$2 >= s && x.$2 < e);
    return true;
  }

  Future<bool> write(
      String day, double value, DateTime start, DateTime end) async {
    writeCalls++;
    if (throwOnWrite.contains(day)) {
      throw StateError('model store write exploded on $day');
    }
    // I4: the plugin boundary must never see anything outside (0, 100].
    // writeOverride stays on the PERCENT level, so the assertion is in
    // percent here.
    expect(value, predicate<double>(
            (v) => v.isFinite && v > 0 && v <= 100,
            'a value in (0, 100], got $value'),
        reason: 'I4: out-of-range value reached the store boundary');
    if (refuseWrites.contains(day)) return false;
    own.add((day, start.millisecondsSinceEpoch,
        end.millisecondsSinceEpoch, value));
    return true;
  }

  List<(int, int, double)> samplesOf(String day) =>
      [for (final s in own) if (s.$1 == day) (s.$2, s.$3, s.$4)]..sort();
}

/// Drives the REAL production pass with this file's store double. The
/// production seam `debugRunSpo2Pass` IS the production pass.
class _DbPassRunner {
  static Future<void> run(
    _Store store, {
    required bool interpretationVerified,
    int Function()? nowMs,
  }) =>
      HealthExporter.shared.debugRunSpo2Pass(
        write: (v, s, e) {
          final day =
              '${s.year}-${s.month.toString().padLeft(2, '0')}-${s.day.toString().padLeft(2, '0')}';
          return store.write(day, v, s, e);
        },
        deleteWindow: (s, e) {
          final day =
              '${s.year}-${s.month.toString().padLeft(2, '0')}-${s.day.toString().padLeft(2, '0')}';
          return store.deleteWindow(day, s, e);
        },
        interpretationVerified: interpretationVerified,
        nowMs: nowMs,
      );
}
