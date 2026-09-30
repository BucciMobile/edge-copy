// Schema-55 regressions: the step-calibration learning tables and the
// wearing-location writer. Run against the REAL LocalDb over sqflite_ffi, the
// same discipline as db_migration_ladder_test — the ladder is one transaction
// and a throwing rung bricks the app, so every new rung gets its own end-to-end
// open-from-old-version test.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/step_calibration.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
  });

  test('a fresh install creates the learning tables at the current schema',
      () async {
    LocalDb.dbName = 'step_cal_fresh.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance; // force open + onCreate ladder
    final cols = await LocalDb.instance;
    final tables = await cols.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
      "('step_calibration','step_calibration_day')",
    );
    expect(tables.length, 2);
    await LocalDb.close();
  });

  test('a v54 database upgrades to 55 and both tables exist', () async {
    LocalDb.dbName = 'step_cal_upgrade.db';
    final dir = await databaseFactory.getDatabasesPath();
    final path = p.join(dir, LocalDb.dbName);
    await databaseFactory.deleteDatabase(path);
    // Hand-build a v54 database: open a raw db at version 54 with nothing in
    // it, then let LocalDb take it up the ladder. The empty schema is fine —
    // the rungs under test are CREATE TABLE IF NOT EXISTS.
    final raw = await databaseFactory.openDatabase(
      path,
      version: 54,
      onConfigure: (db) async {
        await db.execute('CREATE TABLE device (id TEXT PRIMARY KEY)');
      },
    );
    await raw.close();
    final db = await LocalDb.instance;
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
      "('step_calibration','step_calibration_day')",
    );
    expect(tables.length, 2);
    await LocalDb.close();
  });

  test('the wearing setter and reader round-trip through device.wearing',
      () async {
    LocalDb.dbName = 'step_cal_wearing.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
    // No device row yet: the reader refuses rather than inventing wrist.
    expect(await LocalDb.deviceWearing(), isNull);
    // Writing without a row is a no-op UPDATE that reports zero rows —
    // the picker must not claim a save for it.
    expect(await LocalDb.setDeviceWearing(Wearing.bicep), 0);
    expect(await LocalDb.deviceWearing(), isNull);
    // A device row appears (as pairing creates it), the write lands and
    // stamps when it was set.
    await LocalDb.upsertDevice(adapterId: 'gen5');
    expect(await LocalDb.deviceWearing(), Wearing.wrist); // column DEFAULT
    expect(await LocalDb.deviceWearingSetTs(), isNull); // never re-stamped
    expect(await LocalDb.setDeviceWearing(Wearing.bicep), 1);
    expect(await LocalDb.deviceWearing(), Wearing.bicep);
    final firstStamp = await LocalDb.deviceWearingSetTs();
    expect(firstStamp, isNotNull);
    // Re-selecting the SAME location is a no-op for the stamp: a fresh stamp
    // would deactivate the learned profile for the whole history.
    expect(await LocalDb.setDeviceWearing(Wearing.bicep), 1);
    expect(await LocalDb.deviceWearingSetTs(), firstStamp);
    expect(await LocalDb.setDeviceWearing(Wearing.other), 1);
    expect(await LocalDb.deviceWearing(), Wearing.other);
    expect(
      await LocalDb.deviceWearingSetTs(),
      predicate<int?>((t) => t == null || t >= firstStamp!),
    );
    await LocalDb.close();
  });

  test('profile put/read round-trips and refuses foreign versions',
      () async {
    LocalDb.dbName = 'step_cal_profile.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    final db = await LocalDb.instance;
    expect(
      await LocalDb.stepCalibrationProfile('gen5', Wearing.bicep),
      isNull,
    );
    const profile = StepCalibrationProfile(
      deviceFamily: 'gen5',
      wearing: Wearing.bicep,
      factor: 1.4,
      nDays: 6,
      version: kStepCalibrationVersion,
    );
    await LocalDb.putStepCalibrationProfile(profile);
    final back = await LocalDb.stepCalibrationProfile('gen5', Wearing.bicep);
    expect(back!.factor, 1.4);
    expect(back.nDays, 6);
    expect(back.version, kStepCalibrationVersion);
    // A foreign version is invisible to this code, never re-applied.
    await db.insert('step_calibration', {
      'device_family': 'gen5',
      'wearing': Wearing.other,
      'factor': 9.9,
      'n_days': 999,
      'version': kStepCalibrationVersion + 1,
      'updated_ts': 0,
    });
    expect(await LocalDb.stepCalibrationProfile('gen5', Wearing.other), isNull);
    await LocalDb.close();
  });

  test('day observations bank idempotently and read back most-recent-first',
      () async {
    LocalDb.dbName = 'step_cal_days.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
    await LocalDb.putStepCalibrationDay(
      day: '2026-01-01',
      deviceFamily: 'gen5',
      wearing: Wearing.wrist,
      referenceSteps: 8000,
      counterTicks: 10000,
    );
    // Same key: replace, not append.
    await LocalDb.putStepCalibrationDay(
      day: '2026-01-01',
      deviceFamily: 'gen5',
      wearing: Wearing.wrist,
      referenceSteps: 9000,
      counterTicks: 10000,
    );
    await LocalDb.putStepCalibrationDay(
      day: '2026-01-02',
      deviceFamily: 'gen5',
      wearing: Wearing.wrist,
      // Null reference: the phone did not cover this day — absent, not 0.
      referenceSteps: null,
      counterTicks: 500,
    );
    final rows = await LocalDb.stepCalibrationDays('gen5', Wearing.wrist);
    expect(rows.length, 2);
    expect(rows.first['day'], '2026-01-02'); // DESC
    expect(rows.first['reference_steps'], isNull);
    expect(rows.last['reference_steps'], 9000); // replaced, not doubled
    await LocalDb.close();
  });
}
