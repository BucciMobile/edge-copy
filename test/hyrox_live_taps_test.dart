// PR 3 tests: live double-tap bursts -> HYROX boundaries (gesture), with the
// same burst rule and per-station floors as the offline reconciler.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/state/hyrox_live_taps.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/hyrox_plan.dart';
import 'package:openstrap_edge/data/hyrox_store.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
  });

  group('LiveBurstDetector (pure)', () {
    test('three taps inside the window anchored on the first are one burst',
        () {
      final d = LiveBurstDetector();
      expect(d.addTap(1000), isNull);
      expect(d.addTap(1002), isNull);
      expect(d.addTap(1004), 1000); // boundary = FIRST tap
    });

    test('a chained 0/6/12 s sequence is NOT one burst', () {
      final d = LiveBurstDetector();
      expect(d.addTap(1000), isNull);
      expect(d.addTap(1006), isNull); // within 6 s of first
      expect(d.addTap(1012), isNull); // 12 s after first -> new cluster
      expect(d.addTap(1013), isNull);
      expect(d.addTap(1014), 1012); // second burst anchored at 1012
    });

    test('two taps never clear the gate', () {
      final d = LiveBurstDetector();
      expect(d.addTap(1000), isNull);
      expect(d.addTap(1001), isNull);
      expect(d.addTap(5000), isNull); // stale cluster reset, single tap
    });
  });

  group('HyroxLiveTapHandler against real DB', () {
    Future<Database> freshDb(String name) async {
      LocalDb.dbName = name;
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      return LocalDb.instance;
    }

    Future<HyroxLiveTapHandler> handlerFor(Database db, {void Function(String)? log}) async {
      return HyroxLiveTapHandler(() async => db, log: log);
    }

    Future<void> burst(HyroxLiveTapHandler h, int first) async {
      for (final o in [0, 1, 2]) {
        await h.onEvent(14, first + o, '');
      }
    }

    test('no session: taps are ignored without throwing', () async {
      final db = await freshDb('hx_live_none.db');
      final h = await handlerFor(db);
      await burst(h, 1000);
      expect(await HyroxDb.activeSession(db), isNull);
      await LocalDb.close();
    });

    test('a burst starts an armed race, later bursts close rounds, the last '
        'finishes it', () async {
      final db = await freshDb('hx_live_race.db');
      final t0 = 1_000_000;
      await HyroxDb.create(db, HyroxSession(
        id: 'hx_live_1', kind: 'race', preset: 'hyrox', status: 'armed',
        plan: HyroxPlan.race('hyrox'),
        createdAt: t0 * 1000, updatedAt: t0 * 1000,
      ));
      final h = await handlerFor(db);
      await burst(h, t0 + 100); // start
      var segs = await HyroxDb.segments(db, 'hx_live_1');
      expect(segs[0].startTs, t0 + 100);
      expect(segs[0].boundarySource, 'gesture');
      expect((await HyroxDb.byId(db, 'hx_live_1'))!.status, 'active');

      await burst(h, t0 + 500); // close round 1 (skierg floor 300 s: 400 ok)
      segs = await HyroxDb.segments(db, 'hx_live_1');
      expect(segs[0].endTs, t0 + 500);
      expect(segs[1].startTs, t0 + 500);

      // A burst 60 s into round 2 (sled_push floor 240 s) is ignored.
      await burst(h, t0 + 560);
      segs = await HyroxDb.segments(db, 'hx_live_1');
      expect(segs[1].endTs, isNull);

      // Advance through to the final round and finish.
      var t = t0 + 500;
      for (var i = 1; i < 7; i++) {
        t += 600;
        await burst(h, t);
      }
      t += 600;
      await burst(h, t); // finish
      final read = await HyroxDb.byId(db, 'hx_live_1');
      expect(read!.status, 'finished');
      expect(read.segments.last.endTs, t);
      expect(read.segments.every((s) => s.endTs != null), isTrue);
      await LocalDb.close();
    });

    test('non-tap events and zero timestamps are ignored', () async {
      final db = await freshDb('hx_live_ignored.db');
      final t0 = 1_000_000;
      await HyroxDb.create(db, HyroxSession(
        id: 'hx_live_2', kind: 'race', preset: 'hyrox', status: 'armed',
        plan: HyroxPlan.race('hyrox'),
        createdAt: t0 * 1000, updatedAt: t0 * 1000,
      ));
      final h = await handlerFor(db);
      await h.onEvent(7, t0 + 100, ''); // not a double-tap
      await h.onEvent(14, 0, ''); // unset RTC
      final segs = await HyroxDb.segments(db, 'hx_live_2');
      expect(segs[0].startTs, isNull);
      await LocalDb.close();
    });

    test('a finalized session is not modified by live taps', () async {
      final db = await freshDb('hx_live_fin.db');
      final t0 = 1_000_000;
      await HyroxDb.create(db, HyroxSession(
        id: 'hx_live_3', kind: 'race', preset: 'hyrox', status: 'armed',
        plan: HyroxPlan.race('hyrox'),
        createdAt: t0 * 1000, updatedAt: t0 * 1000,
      ));
      await HyroxDb.startSegment(
          db: db, sessionId: 'hx_live_3', ts: t0 + 100,
          boundarySource: 'gesture');
      for (var i = 0; i < 7; i++) {
        await HyroxDb.transitionSegment(
            db: db, sessionId: 'hx_live_3', currentIdx: i,
            transitionTs: t0 + 1000 + i * 600, boundarySource: 'gesture');
      }
      await HyroxDb.finishSegment(
          db: db, sessionId: 'hx_live_3', ts: t0 + 1000 + 7 * 600 + 600,
          boundarySource: 'gesture');
      await HyroxDb.finalize(db, 'hx_live_3');
      final h = await handlerFor(db);
      await burst(h, t0 + 9999);
      final segs = await HyroxDb.segments(db, 'hx_live_3');
      expect(segs[7].endTs, t0 + 1000 + 7 * 600 + 600);
      await LocalDb.close();
    });
  });
}
