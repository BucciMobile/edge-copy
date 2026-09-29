// The imported SpO2 surface — what it is, whose number it is, and what can
// never happen to it.
//
// Three claims are pinned here, and each one exists because its violation
// shipped before:
//
//   * the metric is SUPPRESSED, not charted. A chart draws vendor-imported
//     points under the same line as band-derived ones with no provenance
//     axis, which is how a WHOOP night and a measured night end up compared
//     as if the same maths produced both.
//   * the band's own derivation NEVER writes the key. `putDayResult` replaces
//     `metric_series` wholesale, so one careless `'spo2': null` in the
//     engine's series map would blank every imported value on re-derive.
//     The import path is the only writer.
//   * the catalogue carries the row. An imported number nobody can see is
//     indistinguishable from a number the app dropped.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/substrate.dart' show localDateLabel;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/import/whoop_import.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart' show catalogueKeys;
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

  test('the spo2 spec exists, is suppressed, and claims no input signal', () {
    final s = specOf('spo2');
    expect(s.suppress, isNotNull,
        reason: 'imported vendor values must not be charted alongside '
            'band-derived points');
    expect(s.requires, isEmpty,
        reason: 'an imported scalar requires no device signal; a non-empty '
            'set would gate the row behind devices that can never produce it');
  });

  test('the Explore catalogue lists the imported blood-oxygen row', () {
    expect(catalogueKeys, contains('spo2'));
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

  // The point of the imported-values surface (CodeRabbit, OpenStrap/edge#472):
  // a suppressed spec used to load NO series at all, so the catalogue row was
  // a door that opened onto a bare wall — the imported numbers were stored
  // and nobody could see them. `importedValues` is the flag that lets the
  // suppressed spec load its series without ever charting it.
  test('a suppressed imported spec still loads its stored series', () async {
    final spec = specOf('spo2');
    expect(spec.importedValues, isTrue,
        reason: 'the spec must load its imported series despite suppression');
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
    expect(d.series, isNotEmpty,
        reason: 'the imported values must be loadable for the dated table, '
            'else the catalogue row cannot show what the importer wrote');
    expect(d.series.last.v, 95.1);
    // skin_temp is suppressed WITHOUT imported values — its load must stay
    // empty; the flag must not leak suppression's refusal of the chart into
    // other suppressed specs' data.
    final skin = await MetricData.load(repo, 'skin_temp');
    expect(skin.series, isEmpty,
        reason: 'plain suppressed specs load nothing; only the imported '
            'scalar spec has values worth loading');
  });
}
