// PR 2 tests: the sync-path hook reconcileActiveSession — runs after any
// durable band-data persist, rebuilds only the ONE active session, never
// throws, never touches finalized/discarded sessions.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/state/hyrox_reconciler.dart';
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

  Future<Database> freshDb(String name) async {
    LocalDb.dbName = name;
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    return LocalDb.instance;
  }

  Future<void> taps(Database db, int first, List<int> offsets) async {
    for (final o in offsets) {
      final ts = first + o;
      await db.insert('band_events', {
        'device_id': '',
        'hex': 'dtap_$ts',
        'event_id': 14,
        'name': 'DOUBLE_TAP',
        'ts': ts,
        'payload_json': '{}',
        'captured_at': ts * 1000,
      });
    }
  }

  HyroxSession armed(String id, int createdAtSec) => HyroxSession(
        id: id,
        kind: 'race',
        preset: 'hyrox',
        status: 'armed',
        plan: HyroxPlan.race('hyrox'),
        createdAt: createdAtSec * 1000,
        updatedAt: createdAtSec * 1000,
      );

  test('no active session is a no-op and does not throw', () async {
    final db = await freshDb('hx_hook_empty.db');
    await reconcileActiveSession(db); // must not throw
    await LocalDb.close();
  });

  test('an active armed session is reconciled from stored taps', () async {
    final db = await freshDb('hx_hook_active.db');
    final t0 = 1_000_000;
    await HyroxDb.create(db, armed('hx_hook_1', t0));
    await taps(db, t0 + 600, [0, 2, 4]); // accepted start burst
    await taps(db, t0 + 1200, [0, 1, 2]); // accepted: closes round 1
    final lines = <String>[];
    await reconcileActiveSession(db, log: lines.add);
    final segs = await HyroxDb.segments(db, 'hx_hook_1');
    expect(segs[0].startTs, t0 + 600);
    expect(segs[0].endTs, t0 + 1200);
    expect(segs[1].startTs, t0 + 1200);
    expect(lines.any((l) => l.contains('reconciled')), isTrue);
    // Idempotent: second call changes nothing and logs nothing new.
    final before = lines.length;
    await reconcileActiveSession(db, log: lines.add);
    expect(lines.length, before);
    await LocalDb.close();
  });

  test('a finalized session is never touched', () async {
    final db = await freshDb('hx_hook_finalized.db');
    final t0 = 1_000_000;
    await HyroxDb.create(db, armed('hx_hook_fin', t0));
    await HyroxDb.startSegment(
        db: db, sessionId: 'hx_hook_fin', ts: t0 + 100,
        boundarySource: 'gesture');
    for (var i = 0; i < 7; i++) {
      await HyroxDb.transitionSegment(
          db: db, sessionId: 'hx_hook_fin', currentIdx: i,
          transitionTs: t0 + 1000 + i * 600, boundarySource: 'gesture');
    }
    await HyroxDb.finishSegment(
        db: db, sessionId: 'hx_hook_fin', ts: t0 + 1000 + 7 * 600 + 600,
        boundarySource: 'gesture');
    await HyroxDb.finalize(db, 'hx_hook_fin');
    await taps(db, t0 + 5000, [0, 1, 2]);
    await reconcileActiveSession(db); // finalized -> skipped inside reconcile
    final segs = await HyroxDb.segments(db, 'hx_hook_fin');
    expect(segs[7].endTs, t0 + 1000 + 7 * 600 + 600); // unchanged
    await LocalDb.close();
  });

  test('a discarded session is not resurrected by the sync hook', () async {
    final db = await freshDb('hx_hook_discarded.db');
    final t0 = 1_000_000;
    await HyroxDb.create(db, armed('hx_hook_disc', t0));
    final current = (await HyroxDb.byId(db, 'hx_hook_disc'))!;
    await HyroxDb.updateSession(
      db,
      HyroxSession(
        id: current.id, kind: current.kind, preset: current.preset,
        status: 'discarded', plan: current.plan,
        createdAt: current.createdAt, updatedAt: current.updatedAt,
      ),
    );
    await taps(db, t0 + 600, [0, 1, 2]);
    await reconcileActiveSession(db);
    final read = await HyroxDb.byId(db, 'hx_hook_disc');
    expect(read!.status, 'discarded');
    expect(read.segments[0].startTs, isNull);
    await LocalDb.close();
  });
}
