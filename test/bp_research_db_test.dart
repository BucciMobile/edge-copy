// The BP research store guarantees the review fixes made explicit:
//   · a retake with NO device text replaces the reference instead of
//     duplicating it (NULL never equals NULL in a UNIQUE constraint, so
//     the store normalizes to '' — the rows must stay one, not two);
//   · deleting a capture removes its window row in the same transaction
//     (no PRAGMA foreign_keys here, so the ON DELETE CASCADE is inert);
//   · a retake that now finds band data replaces the old window instead
//     of orphaning it under the replaced reference's old id.
// Runs the REAL LocalDb over sqflite_common_ffi.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/bp_research_capture.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _at = 1700000000000; // ms

BpResearchCapture _capture(
  int measuredAtMs, {
  String? device,
  BpResearchWindow? window,
}) =>
    BpResearchCapture(
      measuredAtMs: measuredAtMs,
      device: device,
      posture: 'sitting',
      conditions: 'rest',
      systolicMmHg: 120,
      diastolicMmHg: 80,
      capturedAtMs: measuredAtMs,
      window: window,
    );

const _win = BpResearchWindow(
  windowStartMs: _at - 120000,
  windowEndMs: _at + 120000,
  onehzRows: 240,
  rrBeats: 200,
  hrMean: 62.5,
  rrMsMean: 960,
  rrMsMin: 800,
  rrMsMax: 1100,
  rmssdMs: 42,
  metaJson: null,
);

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'bp_research_db_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    final db = await LocalDb.instance;
    await db.close();
  });

  test('a retake with no device replaces the reference, not duplicates it',
      () async {
    await LocalDb.putBpResearchCapture(_capture(_at));
    await LocalDb.putBpResearchCapture(_capture(_at, window: _win));
    final rows = await LocalDb.bpResearchCaptures();
    expect(rows, hasLength(1));
    expect(rows.first['device'], '');
    expect(rows.first['hr_mean'], 62.5);
  });

  test('a named device stays distinct from the no-device row', () async {
    await LocalDb.putBpResearchCapture(_capture(_at, device: 'omron'));
    final rows = await LocalDb.bpResearchCaptures();
    expect(rows, hasLength(2)); // the '' row from the previous test + omron
    expect(rows.where((r) => r['device'] == 'omron'), hasLength(1));
  });

  test('delete removes the window row too (the SQL cascade is inert)',
      () async {
    final db = await LocalDb.instance;
    final before =
        await db.rawQuery('SELECT COUNT(*) c FROM bp_research_window');
    expect(before.first['c'], greaterThan(0));
    final refs = await db
        .rawQuery('SELECT id FROM bp_research_reference WHERE device = ?',
            ['omron']);
    await LocalDb.deleteBpResearchCapture(refs.first['id'] as int);
    final orphaned = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_window '
      'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
    );
    expect(orphaned.first['c'], 0);
  });

  test('a retake that now finds band data replaces the absent window',
      () async {
    final later = _at + 60000;
    await LocalDb.putBpResearchCapture(_capture(later));
    await LocalDb.putBpResearchCapture(_capture(later, window: _win));
    final db = await LocalDb.instance;
    final windows = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_window '
        'WHERE reference_id IN '
        '(SELECT id FROM bp_research_reference WHERE measured_at_ms = ?)',
        [later]);
    expect(windows.first['c'], 1);
    final orphaned = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_window '
      'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
    );
    expect(orphaned.first['c'], 0);
  });

  test('the research tables ride the backup restore and salvage lists',
      () async {
    expect(LocalDb.restoreTablesForTest, contains('bp_research_reference'));
    expect(LocalDb.restoreTablesForTest, contains('bp_research_window'));
    expect(LocalDb.salvageTablesForTest, contains('bp_research_reference'));
    expect(LocalDb.salvageTablesForTest, contains('bp_research_window'));
    // Parent before child, in both lists.
    int posOf(List<String> l, String t) => l.indexOf(t);
    expect(
      posOf(LocalDb.restoreTablesForTest, 'bp_research_reference'),
      lessThan(posOf(LocalDb.restoreTablesForTest, 'bp_research_window')),
    );
    expect(
      posOf(LocalDb.salvageTablesForTest, 'bp_research_reference'),
      lessThan(posOf(LocalDb.salvageTablesForTest, 'bp_research_window')),
    );
  });
}
