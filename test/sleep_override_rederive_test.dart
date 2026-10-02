// A sleep correction has to reach the derived day: it must not be dropped
// because another derive pass holds the latch, and the morning readiness pin
// must not keep showing the uncorrected night.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_sleep_override_rederive_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an edit made while another derive pass runs waits for it', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    DerivationEngine.debugRunning = true; // a drain pass / rescan in flight
    addTearDown(() => DerivationEngine.debugRunning = false);

    var done = false;
    final edit = app.reanalyzeForNapEdit().then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(done, isFalse,
        reason: 'run() would have returned 0 and the edit was lost');

    DerivationEngine.debugRunning = false;
    await edit;
    expect(done, isTrue);
  });

  test('correcting the pinned day releases the morning pin', () async {
    await LocalDb.setFrozenHeadline('2026-09-30', 45);
    await LocalDb.putSleepOverride(
      dayId: '2026-09-29',
      onsetTs: 1000,
      offsetTs: 2000,
      source: 'manual',
    );
    expect((await LocalDb.frozenHeadline())?.value, 45,
        reason: 'another day\'s edit leaves today\'s pin alone');

    await LocalDb.putSleepOverride(
      dayId: '2026-09-30',
      onsetTs: 1000,
      offsetTs: 2000,
      source: 'manual',
    );
    expect(await LocalDb.frozenHeadline(), isNull);

    await LocalDb.setFrozenHeadline('2026-09-30', 62);
    await LocalDb.deleteSleepOverride('2026-09-30');
    expect(await LocalDb.frozenHeadline(), isNull);
  });
}
