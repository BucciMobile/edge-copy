// WHOOP exports write wall-clock times with no offset and carry the offset in
// a separate "Cycle timezone" column. Reading those times in the phone's
// current zone put every night or workout recorded somewhere else at the wrong
// instant (and wrote it to Apple Health / Health Connect that way). These
// assertions are absolute epochs, so they hold whatever zone the test runs in.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/import/whoop_import.dart';

int _utc(int y, int mo, int d, int h, [int mi = 0]) =>
    DateTime.utc(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

void main() {
  group('zoneOffset', () {
    test('reads the export formats', () {
      expect(WhoopImporter.zoneOffset('UTC+01:00'), const Duration(hours: 1));
      expect(WhoopImporter.zoneOffset('UTC-08:00'), const Duration(hours: -8));
      expect(WhoopImporter.zoneOffset('UTC+0530'),
          const Duration(hours: 5, minutes: 30));
      expect(WhoopImporter.zoneOffset('GMT+5:30'),
          const Duration(hours: 5, minutes: 30));
      expect(WhoopImporter.zoneOffset('-03:00'), const Duration(hours: -3));
      expect(WhoopImporter.zoneOffset('UTC'), Duration.zero);
    });

    test('anything unreadable falls back to the phone zone', () {
      expect(WhoopImporter.zoneOffset(''), isNull);
      expect(WhoopImporter.zoneOffset('Europe/Paris'), isNull);
      expect(WhoopImporter.zoneOffset('UTC+25:00'), isNull);
    });
  });

  group('parseExportTs', () {
    test('an offset-less time is read in the row zone', () {
      expect(
          WhoopImporter.parseExportTs('2024-03-09 23:10:00', zone: 'UTC+01:00'),
          _utc(2024, 3, 9, 22, 10));
      expect(
          WhoopImporter.parseExportTs('2024-03-09 23:10:00', zone: 'UTC-08:00'),
          _utc(2024, 3, 10, 7, 10));
    });

    test('a time carrying its own offset ignores the zone column', () {
      expect(
          WhoopImporter.parseExportTs('2024-03-09T23:10:00Z',
              zone: 'UTC+01:00'),
          _utc(2024, 3, 9, 23, 10));
      expect(
          WhoopImporter.parseExportTs('2024-03-09 23:10:00+0200',
              zone: 'UTC+01:00'),
          _utc(2024, 3, 9, 21, 10));
    });

    test('no zone column keeps the phone-local reading', () {
      expect(WhoopImporter.parseExportTs('2024-03-09 23:10:00'),
          DateTime(2024, 3, 9, 23, 10).millisecondsSinceEpoch ~/ 1000);
      expect(WhoopImporter.parseExportTs(''), isNull);
    });
  });

  group('import', () {
    late Directory tmp;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_whoop_tz_test.db';
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      tmp = Directory.systemTemp.createTempSync('openstrap_whoop_tz');
    });

    tearDownAll(() async {
      await LocalDb.close();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('a Paris night lands at its real instant and Paris wake date',
        () async {
      final f = File(p.join(tmp.path, 'sleeps.csv'))
        ..writeAsStringSync(
          'Cycle start time,Cycle end time,Cycle timezone,Sleep onset,'
          'Wake onset,Asleep duration (min),In bed duration (min),Nap\n'
          '2024-03-09 23:00:00,2024-03-10 23:00:00,UTC+01:00,'
          '2024-03-09 23:10:00,2024-03-10 07:00:00,440,470,false\n',
        );
      final res = await WhoopImporter.importFiles([f.path]);
      expect(res.days, 1);
      final row = await LocalDb.dayResult('2024-03-10');
      expect(row, isNotNull, reason: 'filed under the Paris wake date');
      final win = jsonDecode(row!['window_json'] as String) as Map;
      expect(win['onset_ms'], _utc(2024, 3, 9, 22, 10) * 1000);
      expect(win['offset_ms'], _utc(2024, 3, 10, 6) * 1000);
    });

    test('a Paris workout is stored at its real instant', () async {
      final f = File(p.join(tmp.path, 'workouts.csv'))
        ..writeAsStringSync(
          'Cycle start time,Cycle end time,Cycle timezone,Workout start time,'
          'Workout end time,Activity name,Activity Strain\n'
          '2024-03-10 07:00:00,2024-03-11 07:00:00,UTC+01:00,'
          '2024-03-10 18:00:00,2024-03-10 18:45:00,Running,11.2\n',
        );
      final res = await WhoopImporter.importFiles([f.path]);
      expect(res.workouts, 1);
      final start = _utc(2024, 3, 10, 17);
      final db = await LocalDb.instance;
      final rows = await db.query('sessions',
          where: 'id = ?', whereArgs: ['whoop_$start']);
      expect(rows, hasLength(1));
      expect((rows.first['start_ts'] as num).toInt(), start);
      expect((rows.first['end_ts'] as num).toInt(), _utc(2024, 3, 10, 17, 45));
    });
  });
}
