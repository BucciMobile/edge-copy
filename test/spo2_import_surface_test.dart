// Imported WHOOP blood oxygen: the importer writes the `spo2` series with
// WHOOP provenance, and the metric screen loads and charts it.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/substrate.dart' show localDateLabel;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/import/whoop_import.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart'
    show MetricData, specOf;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:io';
import 'dart:convert';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('the spo2 spec is charted in percent and claims no device signal', () {
    final s = specOf('spo2');
    expect(s.suppress, isNull);
    expect(s.unit, '%');
    expect(s.requires, isEmpty,
        reason: 'an imported scalar needs no device signal; a non-empty set '
            'would gate the row behind devices that never produce it');
  });

  test('the WHOOP importer writes the spo2 series row from the export column',
      () async {
    final dir = await Directory.systemTemp.createTemp('spo2_import');
    addTearDown(() => dir.delete(recursive: true));
    const wake = '2026-03-09 07:15:00';
    final day = localDateLabel(
        DateTime.parse(wake).millisecondsSinceEpoch ~/ 1000);
    final f = File('${dir.path}/day.csv');
    f.writeAsStringSync(
      'Cycle start time,Wake onset,Sleep onset,Blood oxygen %\n'
      '$wake,$wake,2026-03-08 23:10:00,96.4\n',
    );
    final res = await WhoopImporter.importFiles([f.path]);
    expect(res.days, 1);
    final db = await LocalDb.instance;
    final rows = await db.query('metric_series',
        where: 'date = ? AND key = ?', whereArgs: [day, 'spo2']);
    expect(rows, hasLength(1));
    expect((rows.first['value'] as num?)?.toDouble(), 96.4);
    // Provenance is the vendor's, never the band's.
    final payload = jsonDecode((await db.query('day_result',
            where: 'day_id = ?', whereArgs: [day]))
        .first['payload_json'] as String) as Map;
    expect(payload['source'], 'whoop_export');
    final scalars = payload['scalars'] as Map;
    expect(scalars['spo2'], 96.4);
    expect(
        (payload['flags'] as List).contains('IMPORTED_WHOOP_BETA'), isTrue);
  });

  test('an out-of-range blood oxygen cell is dropped, not charted', () async {
    final dir = await Directory.systemTemp.createTemp('spo2_range');
    addTearDown(() => dir.delete(recursive: true));
    const wake = '2026-03-11 07:15:00';
    final day = localDateLabel(
        DateTime.parse(wake).millisecondsSinceEpoch ~/ 1000);
    final f = File('${dir.path}/day.csv');
    f.writeAsStringSync(
      'Cycle start time,Wake onset,Sleep onset,Blood oxygen %,Resting heart rate (bpm)\n'
      '$wake,$wake,2026-03-10 23:10:00,0,52\n',
    );
    await WhoopImporter.importFiles([f.path]);
    final db = await LocalDb.instance;
    final rows = await db.query('metric_series',
        where: 'date = ? AND key = ?', whereArgs: [day, 'spo2']);
    expect(rows.where((r) => r['value'] != null), isEmpty);
  });

  test('the metric screen loads the imported series', () async {
    final dir = await Directory.systemTemp.createTemp('spo2_visible');
    addTearDown(() => dir.delete(recursive: true));
    const wake = '2026-03-10 07:15:00';
    final f = File('${dir.path}/day.csv');
    f.writeAsStringSync(
      'Cycle start time,Wake onset,Sleep onset,Blood oxygen %\n'
      '$wake,$wake,2026-03-09 23:10:00,95.1\n',
    );
    final res = await WhoopImporter.importFiles([f.path]);
    expect(res.days, 1);
    final repo = LocalRepositoryImpl(
      getProfileMap: () => const <String, dynamic>{},
    );
    final d = await MetricData.load(repo, 'spo2');
    expect(d.series, isNotEmpty);
    expect(d.series.last.v, 95.1);
  });
}
