// PR 4 tests: closed HYROX rounds are banked as `sessions` rows and linked
// (workout_id), idempotently, from both the live and the offline path.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/state/hyrox_workout_banker.dart';
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

  test('closed rounds become linked sessions rows; open/unstarted do not',
      () async {
    final db = await freshDb('hx_bank_1.db');
    final t0 = 1_000_000;
    await HyroxDb.create(db, HyroxSession(
      id: 'hx_bank_1', kind: 'race', preset: 'hyrox', status: 'armed',
      plan: HyroxPlan.race('hyrox'),
      createdAt: t0 * 1000, updatedAt: t0 * 1000,
    ));
    await HyroxDb.startSegment(
        db: db, sessionId: 'hx_bank_1', ts: t0 + 100,
        boundarySource: 'gesture');
    await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_bank_1', currentIdx: 0,
        transitionTs: t0 + 700, boundarySource: 'gesture');

    final linked = await HyroxWorkoutBanker.bankClosedSegments(db, 'hx_bank_1');
    expect(linked, ['hx_bank_1:r0']);
    final segs = await HyroxDb.segments(db, 'hx_bank_1');
    expect(segs[0].workoutId, 'hx_bank_1:r0');
    expect(segs[1].workoutId, isNull); // still open

    final row = await db.query('sessions', where: 'id = ?',
        whereArgs: ['hx_bank_1:r0']);
    expect(row, hasLength(1));
    expect(row.first['start_ts'], t0 + 100);
    expect(row.first['end_ts'], t0 + 700);
    expect(row.first['type'], 'other');
    expect(row.first['status'], 'done');

    // Idempotent: a second run links nothing new.
    final again = await HyroxWorkoutBanker.bankClosedSegments(db, 'hx_bank_1');
    expect(again, isEmpty);
    expect(
      await db.query('sessions', where: "id LIKE 'hx_bank_1:%'"),
      hasLength(1),
    );
    await LocalDb.close();
  });

  test('bankActive only touches the active session and never throws', () async {
    final db = await freshDb('hx_bank_2.db');
    await HyroxWorkoutBanker.bankActive(db); // no session at all
    final t0 = 1_000_000;
    await HyroxDb.create(db, HyroxSession(
      id: 'hx_bank_2', kind: 'race', preset: 'hyrox', status: 'armed',
      plan: HyroxPlan.race('hyrox'),
      createdAt: t0 * 1000, updatedAt: t0 * 1000,
    ));
    await HyroxDb.startSegment(
        db: db, sessionId: 'hx_bank_2', ts: t0 + 100,
        boundarySource: 'gesture');
    await HyroxWorkoutBanker.bankActive(db); // open round: nothing to bank
    expect(
      await db.query('sessions', where: "id LIKE 'hx_bank_2:%'"),
      isEmpty,
    );
    await LocalDb.close();
  });
}
