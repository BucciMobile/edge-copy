// PR 5 tests: the UI controller drives HyroxDb correctly (arm, tap-through
// lifecycle, corrections, finalize, discard) against real sqflite_ffi.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/state/hyrox_controller.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
  });

  Future<HyroxController> fresh(String name) async {
    LocalDb.dbName = name;
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    final db = await LocalDb.instance;
    final c = HyroxController(() async => db);
    await c.refresh();
    return c;
  }

  test('arm creates an armed session; tap walks the whole race to finished',
      () async {
    final c = await fresh('hx_ui_1.db');
    expect(c.session, isNull);
    await c.arm('hyrox');
    expect(c.session, isNotNull);
    expect(c.session!.status, 'armed');
    expect(c.session!.segments, hasLength(8));
    expect(c.isActive, isTrue);

    for (var i = 0; i < 8; i++) {
      await c.tap(); // start + 7 transitions + finish
    }
    expect(c.session!.status, 'finished');
    expect(c.session!.segments.every((s) => s.endTs != null), isTrue);
    expect(c.session!.segments[0].boundarySource, 'phone');

    await c.finalize();
    expect(c.session!.isFinalized, isTrue);
    expect(c.isActive, isFalse);
    await LocalDb.close();
  });

  test('corrections route through adjustBoundary/removeBoundary/adjustStart',
      () async {
    final c = await fresh('hx_ui_2.db');
    await c.arm('hyrox_doubles');
    await c.tap(); // start
    await c.tap(); // close round 1
    final s = c.session!;
    expect(s.segments[0].endTs, isNotNull);

    final b = s.segments[0].endTs!;
    await c.adjustBoundary(0, b + 60);
    expect(c.session!.segments[0].endTs, b + 60);
    expect(c.session!.segments[1].startTs, b + 60);
    expect(c.session!.segments[0].boundarySource, 'manual');

    await c.removeBoundary(0);
    expect(c.session!.segments[0].endTs, isNull);
    expect(c.session!.segments[1].startTs, isNull);

    // Nothing has ended now, so the start can still be moved.
    final st = c.session!.segments[0].startTs!;
    await c.adjustStart(st + 30);
    expect(c.session!.segments[0].startTs, st + 30);
    await LocalDb.close();
  });

  test('discard marks the session discarded and inactive', () async {
    final c = await fresh('hx_ui_3.db');
    await c.arm('hyrox');
    await c.discard();
    expect(c.session!.status, 'discarded');
    expect(c.isActive, isFalse);
    await LocalDb.close();
  });
}
