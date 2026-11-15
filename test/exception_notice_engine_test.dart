// The health-exception push through the real `_runNotifications`: the
// overnight detectors' verdict is dated by the night it is about, a night
// buzzes once however many passes see it, and history does not interrupt.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String dir;
  final shown = <NotificationEvent>[];
  final original = NotificationCenter.instance.presentSink;
  // One fixed clock for the seed AND the pass: labels taken from the real
  // clock at load time go stale if the run crosses midnight. It is read once
  // from the real clock rather than fixed: the fired-key store prunes claims
  // older than its retention against the real clock, so a fixed date ages out
  // and the second pass can claim it again.
  final today = todayLabel();
  final yesterday = dayLabelBefore(today, 1)!;
  Future<void> runPass() =>
      DerivationEngine().runNotificationsForTest(today: today);

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_exception_notice_engine_test.db';
    dir = await databaseFactory.getDatabasesPath();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    NotificationIds.instance.resetForTest();
    shown.clear();
    NotificationCenter.instance.presentSink = (e,
        {bool allowPermissionPrompt = true}) async {
      shown.add(e);
      return true;
    };
  });

  tearDown(() async {
    NotificationCenter.instance.presentSink = original;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  // Today is still settling; the newest settled night carries the verdict.
  // A lone red illness flag with no residual consensus behind it.
  Future<void> seed({required String illnessDate}) => LocalDb.putBaseline(
        'crossday',
        jsonEncode({
          'illness': {'date': illnessDate, 'state': 'red'},
          'recent': [
            {'date': today, 'unsettled': true},
          ],
        }),
      );

  // A tier-3 constellation over the last two settled nights (8 clean nights
  // behind them, so the robust z has a baseline) plus the legacy red illness
  // block on the newest one — the old aggregated notice must stand down in
  // favour of the ask-first check-in.
  Future<void> seedConsensus({required String spikeDate}) {
    final rows = <Map<String, dynamic>>[
      for (var i = 10; i >= 3; i--)
        {
          'date': dayLabelBefore(today, i)!,
          'rhr_residual': 55.0 + (i % 3),
          'hrv_residual': 45.0,
          'resp_residual': 14.0,
          'temp_residual': 3000.0,
        },
      {
        'date': dayLabelBefore(today, 2)!,
        'rhr_residual': 62.0,
        'hrv_residual': 36.0,
        'resp_residual': 17.0,
        'temp_residual': 3048.0,
      },
      {
        'date': spikeDate,
        'rhr_residual': 62.0,
        'hrv_residual': 36.0,
        'resp_residual': 17.0,
        'temp_residual': 3048.0,
      },
      {'date': today, 'unsettled': true},
    ];
    return LocalDb.putBaseline(
      'crossday',
      jsonEncode({
        'illness': {'date': spikeDate, 'state': 'red'},
        'calibration': {
          'stage': 3,
          'valid_nights': 40,
          'signals': {'rhr': 40, 'hrv': 40, 'resp': 40, 'temp': 40},
        },
        'recent': rows,
      }),
    );
  }

  test("yesterday's two-night consensus earns one ask-first check-in, dated and keyed by that night",
      () async {
    await seedConsensus(spikeDate: yesterday);
    await runPass();
    expect(shown, hasLength(1));
    expect(shown.single.date, yesterday);
    expect(shown.single.dedupeKey, '$yesterday:checkin:medical');
    expect(shown.single.route, '/checkin?date=$yesterday&tier=3');
  });

  test('the same night does not buzz twice', () async {
    await seedConsensus(spikeDate: yesterday);
    await runPass();
    await runPass();
    expect(shown, hasLength(1));
  });

  test('a single red night without consensus no longer pushes (persistence rule)',
      () async {
    await seed(illnessDate: yesterday);
    await runPass();
    expect(shown, isEmpty,
        reason:
            'tier >= 2 needs >=2 signals for >=2 nights; a lone CUSUM red is card-only now');
  });

  test('a red night two days back is history', () async {
    await seed(illnessDate: dayLabelBefore(today, 2)!);
    await runPass();
    expect(shown, isEmpty);
  });
}
