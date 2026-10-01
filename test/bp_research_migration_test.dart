// END-TO-END BP research migration regressions over REAL SQLite files,
// in the style of db_migration_ladder_test.dart. Each test hand-builds a
// database file at an OLD schema version (54, 55, or a partially-migrated
// shape), then opens it through LocalDb so sqflite runs the whole onUpgrade
// ladder — and asserts the ladder completed without the
// quarantine-and-rebuild fallback (a bricked rung would still end at the
// current user_version, so version alone proves nothing).
//
// Covered paths:
//   · fresh install (onCreate) — v1 tables + v2 columns in one pass
//   · 54 → 55 → 56 in one app update (the rung-55 tables do not exist yet)
//   · 55 → 56 (tables exist, v2 columns/table do not)
//   · interrupted/unusual upgrade shapes:
//       - v55 file WITHOUT the bp tables (foreign or partial build)
//       - v56 file with rung-55 tables but a missing v2 column
//       - v56 file already fully migrated (idempotent re-open)
//   · backup/restore compatibility: a v1-shaped source DB restores into a
//     v2 target with its v1 rows left honestly NULL in the new columns.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';

const _v1BpDdl = [
  '''
  CREATE TABLE bp_research_reference (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    measured_at_ms INTEGER NOT NULL,
    device TEXT,
    posture TEXT,
    conditions TEXT,
    systolic_mmhg REAL NOT NULL,
    diastolic_mmhg REAL NOT NULL,
    captured_at_ms INTEGER NOT NULL,
    UNIQUE (measured_at_ms, device)
  )''',
  '''
  CREATE TABLE bp_research_window (
    reference_id INTEGER NOT NULL PRIMARY KEY,
    window_start_ms INTEGER NOT NULL,
    window_end_ms INTEGER NOT NULL,
    onehz_rows INTEGER,
    rr_beats INTEGER,
    hr_mean REAL,
    rr_ms_mean REAL,
    rr_ms_min REAL,
    rr_ms_max REAL,
    rmssd_ms REAL,
    meta_json TEXT
  )''',
  'CREATE INDEX idx_bp_research_reference_at '
      'ON bp_research_reference(measured_at_ms)',
];

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// Build a database FILE at [version] with [ddl] applied, optionally with
/// [seedRows], then close it — exactly like a user's old install on disk.
Future<void> _seedOldDb(
  String name,
  int version,
  List<String> ddl, {
  Future<void> Function(Database db)? seedRows,
}) async {
  final path = await _dbPath(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, _) async {
        for (final s in ddl) {
          await db.execute(s);
        }
      },
    ),
  );
  if (seedRows != null) await seedRows(db);
  await db.close();
}

/// Open [name] through LocalDb (running the REAL ladder + repair pass) and
/// assert it completed without the quarantine fallback.
Future<Database> _openThroughLocalDb(String name) async {
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  final db = await LocalDb.instance;
  expect(
    LocalDb.lastRebuild,
    isNull,
    reason:
        'the upgrade bricked and fell back to quarantine-and-rebuild: '
        '${LocalDb.lastRebuild?.cause}',
  );
  final rows = await db.rawQuery('PRAGMA user_version');
  expect((rows.first.values.first as num?)?.toInt(), LocalDb.schemaVersion);
  return db;
}

const _expectedRefV2Cols = [
  'measurement_started_at_ms',
  'measurement_finished_at_ms',
  'band_device_id',
  'measurement_session_id',
  'time_precision',
];

const _expectedWinV2Cols = [
  'observed_start_ms',
  'observed_end_ms',
  'valid_hr_seconds',
  'valid_interval_count',
  'valid_interval_pair_count',
  'coverage_fraction',
  'rejected_interval_fraction',
  'quality_status',
  'feature_version',
  'snapshot_revision',
];

Future<Set<String>> _columns(Database db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return {for (final c in info) c['name'] as String};
}

void main() {
  final created = <String>[];
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _dbPath(n));
    }
  });

  test(
    'fresh install creates v1 tables + all v2 columns in one pass',
    () async {
      const name = 'bp_migrate_fresh_test.db';
      created.add(name);
      await LocalDb.close();
      LocalDb.lastRebuild = null;
      LocalDb.dbName = name;
      await databaseFactory.deleteDatabase(await _dbPath(name));
      final db = await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNull);
      final refCols = await _columns(db, 'bp_research_reference');
      final winCols = await _columns(db, 'bp_research_window');
      for (final c in _expectedRefV2Cols) {
        expect(refCols, contains(c));
      }
      for (final c in _expectedWinV2Cols) {
        expect(winCols, contains(c));
      }
      final snapCols = await _columns(db, 'bp_research_snapshot');
      expect(snapCols, containsAll(['reference_id', 'revision', 'onehz_json']));
    },
  );

  test(
    'upgrade 54 → 56 in one update creates everything, brick-free',
    () async {
      const name = 'bp_migrate_v54_test.db';
      created.add(name);
      // A v54 database has NO bp tables at all; the ladder must create them at
      // rung 55 and add the v2 shape at rung 56 — inside ONE transaction.
      await _seedOldDb(name, 54, const []);
      final db = await _openThroughLocalDb(name);
      expect(
        await db.rawQuery('SELECT name FROM sqlite_master WHERE name = ?', [
          'bp_research_reference',
        ]),
        isNotEmpty,
      );
      expect(
        await db.rawQuery('SELECT name FROM sqlite_master WHERE name = ?', [
          'bp_research_snapshot',
        ]),
        isNotEmpty,
      );
      final refCols = await _columns(db, 'bp_research_reference');
      for (final c in _expectedRefV2Cols) {
        expect(refCols, contains(c));
      }
    },
  );

  test(
    'upgrade 55 → 56 adds v2 columns/table, v1 data stays untouched',
    () async {
      const name = 'bp_migrate_v55_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        55,
        _v1BpDdl,
        seedRows: (db) async {
          await db.insert('bp_research_reference', {
            'measured_at_ms': 1700000000000,
            'device': 'omron',
            'systolic_mmhg': 120.0,
            'diastolic_mmhg': 80.0,
            'captured_at_ms': 1700000060000,
          });
          await db.insert('bp_research_window', {
            'reference_id': 1,
            'window_start_ms': 1699999700000,
            'window_end_ms': 1700000000000,
            'onehz_rows': 300,
            'hr_mean': 61.0,
            'rmssd_ms': 42.0,
          });
        },
      );
      final db = await _openThroughLocalDb(name);
      final winCols = await _columns(db, 'bp_research_window');
      for (final c in _expectedWinV2Cols) {
        expect(winCols, contains(c));
      }
      // The v1 row keeps its data and reads NULL in every v2 column — absent
      // stays absent, nothing is fabricated or rewritten.
      final ref = await db.query('bp_research_reference');
      expect(ref, hasLength(1));
      expect(ref.first['systolic_mmhg'], 120.0);
      expect(ref.first['measurement_started_at_ms'], isNull);
      expect(ref.first['band_device_id'], isNull);
      final win = await db.query('bp_research_window');
      expect(win, hasLength(1));
      expect(win.first['onehz_rows'], 300);
      expect(win.first['quality_status'], isNull);
      expect(win.first['snapshot_revision'], isNull);
    },
  );

  test('a v55 file WITHOUT the bp tables upgrades brick-free', () async {
    // The hardened rung-56 helper must self-create the rung-55 tables
    // instead of throwing "no such table" inside the exclusive transaction.
    const name = 'bp_migrate_v55_missing_tables_test.db';
    created.add(name);
    await _seedOldDb(name, 55, const []);
    final db = await _openThroughLocalDb(name);
    expect(
      await db.rawQuery('SELECT name FROM sqlite_master WHERE name = ?', [
        'bp_research_reference',
      ]),
      isNotEmpty,
    );
    final refCols = await _columns(db, 'bp_research_reference');
    for (final c in _expectedRefV2Cols) {
      expect(refCols, contains(c));
    }
  });

  test('a v56 file missing one v2 column is repaired on open', () async {
    // Same-version merged-build case: the tables exist, one ALTER was
    // skipped by an unusual lineage. _repairOpenSchema must add it back.
    const name = 'bp_migrate_v56_partial_test.db';
    created.add(name);
    await _seedOldDb(name, 56, _v1BpDdl);
    // v1 window shape only (missing ALL v2 window columns) so the repair
    // pass has real work to do on the window table.
    final db = await _openThroughLocalDb(name);
    final winCols = await _columns(db, 'bp_research_window');
    for (final c in _expectedWinV2Cols) {
      expect(winCols, contains(c));
    }
  });

  test('an already-current v56 database re-opens idempotently', () async {
    const name = 'bp_migrate_v56_idempotent_test.db';
    created.add(name);
    await _seedOldDb(name, 56, const []);
    final db = await _openThroughLocalDb(name);
    await db.rawQuery('SELECT 1');
    // Reopen: the repair pass runs the same helpers again on a full schema.
    await LocalDb.close();
    final db2 = await _openThroughLocalDb(name);
    await db2.rawQuery('SELECT 1');
  });

  test(
    'a v1-shaped backup restores into a v2 target with honest NULLs',
    () async {
      const target = 'bp_restore_v1_target_test.db';
      const source = 'bp_restore_v1_source_test.db';
      created.add(target);
      created.add(source);
      await _seedOldDb(
        source,
        55,
        _v1BpDdl,
        seedRows: (db) async {
          await db.insert('bp_research_reference', {
            'measured_at_ms': 1700000000000,
            'device': '',
            'systolic_mmhg': 125.0,
            'diastolic_mmhg': 82.0,
            'captured_at_ms': 1700000060000,
          });
          await db.insert('bp_research_window', {
            'reference_id': 1,
            'window_start_ms': 1699999700000,
            'window_end_ms': 1700000000000,
            'onehz_rows': 200,
            'hr_mean': 58.0,
          });
        },
      );
      await _seedOldDb(target, 56, const []);
      final db = await _openThroughLocalDb(target);
      final counts = await LocalDb.importFromDbFile(await _dbPath(source));
      expect(counts['bp_research_reference'], 1);
      expect(counts['bp_research_window'], 1);
      final ref = await db.query('bp_research_reference');
      expect(ref, hasLength(1));
      expect(ref.first['systolic_mmhg'], 125.0);
      // v1 provenance stays NULL — the import never invents it.
      expect(ref.first['measurement_session_id'], isNull);
      final win = await db.query('bp_research_window');
      expect(win, hasLength(1));
      expect(win.first['onehz_rows'], 200);
      expect(
        win.first['snapshot_revision'],
        isNull,
        reason:
            'a v1 window is snapshotless; the import must not invent a '
            'revision it has no snapshot for',
      );
    },
  );
}
