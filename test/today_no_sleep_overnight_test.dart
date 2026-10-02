// A settled no-sleep morning (strap on the charger overnight) is today's
// overnight per compute freshness. getToday used to read the overnight side
// from the newest day WITH sleep instead, so an older night's readiness
// showed as this morning's with no prior-night label.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_today_no_sleep_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  test('a no-sleep today does not serve an older night as this morning',
      () async {
    final today = todayLabel();
    final now = DateTime.now();
    final yesterday =
        todayLabel(DateTime(now.year, now.month, now.day - 1, 12));
    await LocalDb.putDayResult(
      dayId: yesterday,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {'readiness': 77, 'rmssd': 55},
        'sleep': {
          'accounting': {
            'value': {'tst_sec': 25200},
          },
        },
      }),
      windowJson: '{}',
    );
    await LocalDb.putDayResult(
      dayId: today,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {'steps': 1200},
        'flags': ['NO_SLEEP_DETECTED'],
        'sleep': {
          'accounting': {'value': '—'},
        },
      }),
      windowJson: '{}',
    );
    await LocalDb.refreshComputeFreshness();

    final t = await LocalRepositoryImpl(getProfileMap: () => {}).getToday();
    final status = t['status'] as Map;
    expect(status['overnight_state'], 'ready');
    expect(status['showing_prior_overnight'], isNot(true));
    final readiness = (t['daily'] as Map)['readiness'];
    expect(
        readiness is Map ? readiness['value'] : readiness, isNot(isA<num>()),
        reason: "yesterday's 77 is not this morning's readiness");
  });
}
