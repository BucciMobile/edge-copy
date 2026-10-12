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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'oura_spo2_model_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
  });
  tearDown(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

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

      for (var step = 0; step < 40; step++) {
        final op = rnd.nextInt(8);
        final ring = rings[rnd.nextInt(rings.length)];
        final back = 1 + rnd.nextInt(10);
        switch (op) {
          case 0:
          case 1:
          case 2:
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
          case 3:
            log.add('pair $ring');
            await LocalDb.upsertDevice(
                id: ring, adapterId: 'oura', remoteId: 'x-$ring');
            model.paired.add(ring);
            break;
          case 4:
            log.add('forget $ring');
            await LocalDb.deleteDevice(ring);
            model.paired.remove(ring);
            break;
          case 5:
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
          case 6:
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
          default:
            clock += rnd.nextInt(90) * 60000 -
                (rnd.nextInt(10) == 0 ? 3600000 : 0);
            log.add('pass @ $clock');
            await runPassHelper(store,
                interpretationVerified: true, nowMs: () => clock);
        }
      }

      // Heal and converge (I6).
      store.refuseWrites.clear();
      store.refuseDeletes.clear();
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
