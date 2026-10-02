// #448 — mid-drain, the newest banked record is still inside last night, the
// stager closes the window at it, and Home served that partial night (and the
// readiness off it) as this morning's. Today's overnight only counts as
// `ready` once the data edge has moved past its wake.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late String dir;
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_overnight_settled_test.db';
    dir = await databaseFactory.getDatabasesPath();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    db = await LocalDb.instance;
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Future<void> seed({required int wakeSec, required int edgeSec}) async {
    await db.insert('day_result', {
      'day_id': todayLabel(),
      'algo_version': kAlgoVersion,
      'payload_json': jsonEncode({
        'sleep': {
          'window': {
            'value': {'offset_ms': wakeSec * 1000},
          },
          'accounting': {
            'value': {'tst_sec': 6 * 3600},
          },
        },
      }),
      'window_json': '{}',
      'computed_at': 1,
      'finalized': 0,
    });
    await db.insert('decoded_onehz', {
      'ts_ms': edgeSec * 1000,
      'rec_ts': edgeSec,
      'counter': 1,
      'hr': 60,
    });
  }

  Future<String?> overnightDay() async {
    await LocalDb.refreshComputeFreshness();
    final row = await LocalDb.computeFreshness('today');
    return jsonDecode(row!['payload_json'] as String)['overnight_day'] as String?;
  }

  test('edge still at the wake → today is not the overnight yet', () async {
    final wake = nowSec - 20 * 60;
    await seed(wakeSec: wake, edgeSec: wake + 60);
    expect(await overnightDay(), isNot(todayLabel()));
  });

  test('edge an hour past the wake → today is the overnight', () async {
    final wake = nowSec - 3 * 3600;
    await seed(wakeSec: wake, edgeSec: wake + 2 * 3600);
    expect(await overnightDay(), todayLabel());
  });

  test('a strap that went quiet at wake still settles by the give-up', () {
    final wake = nowSec - 13 * 3600;
    expect(
      overnightSettled(sleepOffsetSec: wake, dataEdgeSec: wake, nowSec: nowSec),
      isTrue,
    );
  });
}
