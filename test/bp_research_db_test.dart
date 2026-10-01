// The BP research store guarantees the review fixes made explicit:
//   · a retake with NO device text replaces the reference instead of
//     duplicating it (NULL never equals NULL in a UNIQUE constraint, so
//     the store normalizes to '' — the rows must stay one, not two);
//   · deleting a capture removes its window row in the same transaction
//     (no PRAGMA foreign_keys here, so the ON DELETE CASCADE is inert);
//   · a retake that now finds band data replaces the old window instead
//     of orphaning it under the replaced reference's old id.
// Runs the REAL LocalDb over sqflite_common_ffi.
import 'dart:convert' show jsonEncode;

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
}) => BpResearchCapture(
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
  featureVersion: kResearchFeatureVersion,
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

  test(
    'a retake with no device replaces the reference, not duplicates it',
    () async {
      await LocalDb.putBpResearchCapture(_capture(_at));
      await LocalDb.putBpResearchCapture(_capture(_at, window: _win));
      final rows = await LocalDb.bpResearchCaptures();
      expect(rows, hasLength(1));
      expect(rows.first['device'], '');
      expect(rows.first['hr_mean'], 62.5);
    },
  );

  test('a named device stays distinct from the no-device row', () async {
    await LocalDb.putBpResearchCapture(_capture(_at, device: 'omron'));
    final rows = await LocalDb.bpResearchCaptures();
    expect(rows, hasLength(2)); // the '' row from the previous test + omron
    expect(rows.where((r) => r['device'] == 'omron'), hasLength(1));
  });

  test(
    'delete removes the window row too (the SQL cascade is inert)',
    () async {
      final db = await LocalDb.instance;
      final before = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_window',
      );
      expect(before.first['c'], greaterThan(0));
      final refs = await db.rawQuery(
        'SELECT id FROM bp_research_reference WHERE device = ?',
        ['omron'],
      );
      await LocalDb.deleteBpResearchCapture(refs.first['id'] as int);
      final orphaned = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_window '
        'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
      );
      expect(orphaned.first['c'], 0);
    },
  );

  test(
    'a retake that now finds band data replaces the absent window',
    () async {
      final later = _at + 60000;
      await LocalDb.putBpResearchCapture(_capture(later));
      await LocalDb.putBpResearchCapture(_capture(later, window: _win));
      final db = await LocalDb.instance;
      final windows = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_window '
        'WHERE reference_id IN '
        '(SELECT id FROM bp_research_reference WHERE measured_at_ms = ?)',
        [later],
      );
      expect(windows.first['c'], 1);
      final orphaned = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_window '
        'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
      );
      expect(orphaned.first['c'], 0);
    },
  );

  test(
    'a retro capture pairs with HISTORICAL rows and keeps entry time',
    () async {
      final db = await LocalDb.instance;
      await db.delete('bp_research_window');
      await db.delete('bp_research_reference');
      final measured = _at; // the cuff reading, this morning
      final entered = _at + 6 * 3600 * 1000; // typed in this evening
      await LocalDb.putBpResearchCapture(
        BpResearchCapture(
          measuredAtMs: measured,
          measurementStartedAtMs: measured,
          systolicMmHg: 120,
          diastolicMmHg: 80,
          capturedAtMs: entered, // ENTRY time, not measurement
          device: 'omron',
          bandDeviceId: LocalDb.kPrimaryDeviceId,
          measurementSessionId: 'morning',
          window: _win,
        ),
      );
      final r = (await LocalDb.bpResearchCaptures()).first;
      expect(r['measured_at_ms'], measured);
      expect(r['measurement_started_at_ms'], measured);
      expect(r['measurement_finished_at_ms'], isNull); // no invented duration
      expect(r['captured_at_ms'], entered); // entry vs measurement
      expect(r['band_device_id'], LocalDb.kPrimaryDeviceId);
      expect(r['measurement_session_id'], 'morning');
    },
  );

  test(
    'a snapshot freezes the raw rows; re-processing writes a new revision',
    () async {
      final db = await LocalDb.instance;
      await db.delete('bp_research_snapshot');
      await db.delete('bp_research_window');
      await db.delete('bp_research_reference');
      final onehz = [
        {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 60},
        {'rec_ts': (_at - 59000) ~/ 1000, 'hr': 62},
      ];
      final rr = [
        {'rr_ts_ms': _at - 60000, 'rr_ms': 1000},
        {'rr_ts_ms': _at - 59000, 'rr_ms': 1050},
      ];
      await LocalDb.putBpResearchCapture(
        BpResearchCapture(
          measuredAtMs: _at,
          systolicMmHg: 120,
          diastolicMmHg: 80,
          capturedAtMs: _at,
          device: 'omron',
          window: researchWindowFrom(
            measuredAtMs: _at,
            onehzRows: onehz,
            rrRows: rr,
          ),
        ),
        snapshotOnehzRows: onehz,
        snapshotRrRows: rr,
      );
      final id =
          (await db.rawQuery(
                'SELECT id FROM bp_research_reference',
              )).first['id']
              as int;
      final snap1 = await db.rawQuery(
        'SELECT revision, onehz_json FROM bp_research_snapshot '
        'WHERE reference_id = ?',
        [id],
      );
      expect(snap1, hasLength(1));
      expect(snap1.first['revision'], 1);
      // The frozen rows are the exact input: reproducible.
      expect(snap1.first['onehz_json'], contains('60'));
      final win = await db.rawQuery(
        'SELECT snapshot_revision, feature_version, quality_status, '
        'valid_interval_pair_count FROM bp_research_window '
        'WHERE reference_id = ?',
        [id],
      );
      expect(win.first['snapshot_revision'], 1);
      expect(win.first['feature_version'], kResearchFeatureVersion);
      expect(win.first['quality_status'], isNotNull);
      expect(win.first['valid_interval_pair_count'], 1);
    },
  );

  test('a retake keeps the reference id and writes revision 2, revision 1'
      ' stays byte-identical', () async {
    final db = await LocalDb.instance;
    await db.delete('bp_research_snapshot');
    await db.delete('bp_research_window');
    await db.delete('bp_research_reference');
    final rows1 = [
      {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 60},
      {'rec_ts': (_at - 59000) ~/ 1000, 'hr': 62},
    ];
    final rr1 = [
      {'rr_ts_ms': _at - 60000, 'rr_ms': 1000},
    ];
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 120,
        diastolicMmHg: 80,
        capturedAtMs: _at,
        device: 'omron',
        window: researchWindowFrom(
          measuredAtMs: _at,
          onehzRows: rows1,
          rrRows: rr1,
        ),
      ),
      snapshotOnehzRows: rows1,
      snapshotRrRows: rr1,
    );
    final idBefore =
        (await db.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;
    final json1 =
        (await db.rawQuery(
              'SELECT onehz_json FROM bp_research_snapshot '
              'WHERE reference_id = ? AND revision = 1',
              [idBefore],
            )).first['onehz_json']
            as String;
    // The retake: DIFFERENT sensor rows for the same natural reference.
    final rows2 = [
      {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 64},
      {'rec_ts': (_at - 59000) ~/ 1000, 'hr': 66},
    ];
    final rr2 = [
      {'rr_ts_ms': _at - 60000, 'rr_ms': 900},
    ];
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 118,
        diastolicMmHg: 79,
        capturedAtMs: _at + 1000,
        device: 'omron',
        window: researchWindowFrom(
          measuredAtMs: _at,
          onehzRows: rows2,
          rrRows: rr2,
        ),
      ),
      snapshotOnehzRows: rows2,
      snapshotRrRows: rr2,
    );
    final idAfter =
        (await db.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;
    // The reference id is STABLE — a retake is an update, not a new row.
    expect(idAfter, idBefore);
    final snaps = await db.rawQuery(
      'SELECT revision, onehz_json FROM bp_research_snapshot '
      'WHERE reference_id = ? ORDER BY revision',
      [idBefore],
    );
    expect(snaps, hasLength(2));
    expect(snaps[0]['revision'], 1);
    expect(snaps[1]['revision'], 2);
    // Revision 1 is untouched — byte-identical history.
    expect(snaps[0]['onehz_json'], json1);
    expect(snaps[0]['onehz_json'], contains('60'));
    expect(snaps[1]['onehz_json'], contains('64'));
    // The window summary points at the CURRENT revision.
    final win = await db.rawQuery(
      'SELECT snapshot_revision FROM bp_research_window '
      'WHERE reference_id = ?',
      [idBefore],
    );
    expect(win.first['snapshot_revision'], 2);
    // The reference fields were updated in place.
    final ref = await db.rawQuery(
      'SELECT systolic_mmhg FROM bp_research_reference WHERE id = ?',
      [idBefore],
    );
    expect(ref.first['systolic_mmhg'], 118.0);
  });

  test(
    'a reference correction (no new snapshot rows) keeps the snapshots',
    () async {
      final db = await LocalDb.instance;
      // Re-capture the SAME natural reference with corrected values but no
      // snapshot rows: a field fix must not touch the snapshot history.
      final id =
          (await db.rawQuery(
                'SELECT id FROM bp_research_reference',
              )).first['id']
              as int;
      final before = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_snapshot '
        'WHERE reference_id = ?',
        [id],
      );
      await LocalDb.putBpResearchCapture(
        BpResearchCapture(
          measuredAtMs: _at,
          systolicMmHg: 117,
          diastolicMmHg: 78,
          capturedAtMs: _at + 2000,
          device: 'omron',
        ),
      );
      final after = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_snapshot '
        'WHERE reference_id = ?',
        [id],
      );
      expect(after.first['c'], before.first['c']);
      final ref = await db.rawQuery(
        'SELECT systolic_mmhg FROM bp_research_reference WHERE id = ?',
        [id],
      );
      expect(ref.first['systolic_mmhg'], 117.0);
    },
  );

  test('overwriting an existing snapshot revision is an integrity error, '
      'not a silent rewrite', () async {
    final db = await LocalDb.instance;
    final id =
        (await db.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;
    final foreignJson = jsonEncode([
      {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 999},
    ]);
    // A second writer claiming the SAME (reference, revision) key with
    // DIFFERENT content must fail loudly: plain INSERT + UNIQUE.
    await expectLater(
      db.insert('bp_research_snapshot', {
        'reference_id': id,
        'revision': 1,
        'onehz_json': foreignJson,
        'rr_json': '[]',
        'created_at_ms': _at,
      }),
      throwsA(isA<Exception>()),
    );
    // The destination revision is untouched.
    final kept = await db.rawQuery(
      'SELECT onehz_json FROM bp_research_snapshot '
      'WHERE reference_id = ? AND revision = 1',
      [id],
    );
    expect(kept, hasLength(1));
    expect(kept.first['onehz_json'], isNot(foreignJson));
  });

  test('delete removes the snapshot rows too', () async {
    final db = await LocalDb.instance;
    final id =
        (await db.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;
    await LocalDb.deleteBpResearchCapture(id);
    final left = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_snapshot '
      'WHERE reference_id = ?',
      [id],
    );
    expect(left.first['c'], 0);
  });

  test(
    'the research tables ride the backup restore and salvage lists',
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
    },
  );

  // A foreign export's AUTOINCREMENT ids are meaningless on this install:
  // its id=1 must never REPLACE an unrelated local capture that happens to
  // hold id=1. The merge keys references on (measured_at_ms, device) and
  // remaps each window onto the DESTINATION reference id.
  test('restore merges captures by natural key, never by source id', () async {
    // Start from a clean store: earlier tests in this file leave rows
    // behind, and this one asserts exact row sets.
    final db0 = await LocalDb.instance;
    await db0.delete('bp_research_window');
    await db0.delete('bp_research_reference');
    // Local state: one capture (id=1 by AUTOINCREMENT) plus its window.
    await LocalDb.putBpResearchCapture(_capture(_at, device: 'local'));
    // A foreign export whose DIFFERENT capture also carries id=1.
    final srcPath = p.join(
      await databaseFactory.getDatabasesPath(),
      'bp_foreign.db',
    );
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
      'CREATE TABLE bp_research_reference ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'measured_at_ms INTEGER NOT NULL, '
      'device TEXT, posture TEXT, conditions TEXT, '
      'systolic_mmhg REAL NOT NULL, diastolic_mmhg REAL NOT NULL, '
      'captured_at_ms INTEGER NOT NULL, '
      'UNIQUE (measured_at_ms, device))',
    );
    await src.execute(
      'CREATE TABLE bp_research_window ('
      'reference_id INTEGER NOT NULL PRIMARY KEY, '
      'window_start_ms INTEGER NOT NULL, window_end_ms INTEGER NOT NULL, '
      'onehz_rows INTEGER, rr_beats INTEGER, hr_mean REAL, rr_ms_mean REAL, '
      'rr_ms_min REAL, rr_ms_max REAL, rmssd_ms REAL, meta_json TEXT)',
    );
    await src.insert('bp_research_reference', {
      'id': 1, // deliberately collides with the local capture's id
      'measured_at_ms': _at + 60000,
      'device': 'local',
      'posture': 'sitting',
      'conditions': 'rest',
      'systolic_mmhg': 130,
      'diastolic_mmhg': 85,
      'captured_at_ms': _at + 60000,
    });
    await src.insert('bp_research_window', {
      'reference_id': 1,
      'window_start_ms': _at + 60000 - 120000,
      'window_end_ms': _at + 60000 + 120000,
      'onehz_rows': 240,
      'rr_beats': 200,
      'hr_mean': 71.0,
    });
    await src.close();

    final counts = await LocalDb.importFromDbFile(srcPath);
    expect(counts['bp_research_reference'], 1);
    expect(counts['bp_research_window'], 1);

    final db = await LocalDb.instance;
    // Both captures survive: the foreign id=1 did not eat the local one.
    final refs = await db.rawQuery(
      'SELECT measured_at_ms, systolic_mmhg FROM bp_research_reference '
      'ORDER BY measured_at_ms',
    );
    expect(refs, hasLength(2));
    expect(refs[0]['measured_at_ms'], _at);
    expect(refs[0]['systolic_mmhg'], 120.0);
    expect(refs[1]['measured_at_ms'], _at + 60000);
    expect(refs[1]['systolic_mmhg'], 130.0);
    // The imported window rides the imported reference's DESTINATION id,
    // and no window is orphaned.
    final orphaned = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_window '
      'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
    );
    expect(orphaned.first['c'], 0);
    final importedWin = await db.rawQuery(
      'SELECT hr_mean FROM bp_research_window w '
      'JOIN bp_research_reference r ON r.id = w.reference_id '
      'WHERE r.measured_at_ms = ?',
      [_at + 60000],
    );
    expect(importedWin.first['hr_mean'], 71.0);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('a colliding restore keeps the destination id and its window', () async {
    final db0 = await LocalDb.instance;
    await db0.delete('bp_research_window');
    await db0.delete('bp_research_reference');
    // Local capture WITH a window.
    await LocalDb.putBpResearchCapture(
      _capture(_at, device: 'local', window: _win),
    );
    final localId =
        (await db0.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;

    // A foreign export of the SAME instant (same natural key) with no
    // window row: the capture's fields update, the window survives.
    final srcPath = p.join(
      await databaseFactory.getDatabasesPath(),
      'bp_foreign3.db',
    );
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
      'CREATE TABLE bp_research_reference ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'measured_at_ms INTEGER NOT NULL, '
      'device TEXT, posture TEXT, conditions TEXT, '
      'systolic_mmhg REAL NOT NULL, diastolic_mmhg REAL NOT NULL, '
      'captured_at_ms INTEGER NOT NULL, '
      'UNIQUE (measured_at_ms, device))',
    );
    await src.insert('bp_research_reference', {
      'id': 7,
      'measured_at_ms': _at,
      'device': 'local',
      'posture': 'standing',
      'conditions': 'after exercise',
      'systolic_mmhg': 140,
      'diastolic_mmhg': 90,
      'captured_at_ms': _at + 1000,
    });
    await src.close();

    await LocalDb.importFromDbFile(srcPath);

    final db = await LocalDb.instance;
    final refs = await db.rawQuery(
      'SELECT id, posture, systolic_mmhg FROM bp_research_reference',
    );
    expect(refs, hasLength(1));
    // The destination id is KEPT, so the window stays attached.
    expect(refs.first['id'], localId);
    expect(refs.first['posture'], 'standing');
    expect(refs.first['systolic_mmhg'], 140.0);
    final orphaned = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_window '
      'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
    );
    expect(orphaned.first['c'], 0);
    final win = await db.rawQuery(
      'SELECT hr_mean FROM bp_research_window WHERE reference_id = ?',
      [localId],
    );
    expect(win.first['hr_mean'], 62.5);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('a re-import of the same export converges (idempotent merge)', () async {
    final db0 = await LocalDb.instance;
    await db0.delete('bp_research_window');
    await db0.delete('bp_research_reference');
    final srcPath = p.join(
      await databaseFactory.getDatabasesPath(),
      'bp_foreign2.db',
    );
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
      'CREATE TABLE bp_research_reference ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'measured_at_ms INTEGER NOT NULL, '
      'device TEXT, posture TEXT, conditions TEXT, '
      'systolic_mmhg REAL NOT NULL, diastolic_mmhg REAL NOT NULL, '
      'captured_at_ms INTEGER NOT NULL, '
      'UNIQUE (measured_at_ms, device))',
    );
    await src.insert('bp_research_reference', {
      'id': 1,
      'measured_at_ms': _at + 120000,
      'device': '',
      'systolic_mmhg': 118,
      'diastolic_mmhg': 76,
      'captured_at_ms': _at + 120000,
    });
    await src.close();

    await LocalDb.importFromDbFile(srcPath);
    await LocalDb.importFromDbFile(srcPath);
    final db = await LocalDb.instance;
    final n = (await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_reference '
      'WHERE measured_at_ms = ?',
      [_at + 120000],
    )).first['c'];
    expect(n, 1);
    await databaseFactory.deleteDatabase(srcPath);
  });
}
