// Schema 55: step-calibration tables and the wearing writer, on the real
// LocalDb over sqflite_ffi. The upgrade path is covered by
// db_migration_ladder_test.
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

  test('the wearing setter and reader round-trip through device.wearing',
      () async {
    LocalDb.dbName = 'step_cal_wearing.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
    Future<int?> stamp() async =>
        ((await LocalDb.deviceRow())?['wearing_set_ts'] as num?)?.toInt();
    // No device row yet: nothing to read, and the setter reports no save.
    expect(await LocalDb.deviceWearingRaw(), isNull);
    expect(await LocalDb.setDeviceWearing(Wearing.bicep), 0);
    expect(await LocalDb.deviceWearingRaw(), isNull);
    await LocalDb.upsertDevice(adapterId: 'gen5');
    expect(await LocalDb.deviceWearingRaw(), Wearing.wrist); // column DEFAULT
    expect(await stamp(), isNull);
    // Re-picking the default is not a change and must not stamp.
    expect(await LocalDb.setDeviceWearing(Wearing.wrist), 1);
    expect(await stamp(), isNull);
    expect(await LocalDb.setDeviceWearing(Wearing.bicep), 1);
    expect(await LocalDb.deviceWearingRaw(), Wearing.bicep);
    final firstStamp = await stamp();
    expect(firstStamp, isNotNull);
    expect(await LocalDb.setDeviceWearing(Wearing.bicep), 1);
    expect(await stamp(), firstStamp);
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
