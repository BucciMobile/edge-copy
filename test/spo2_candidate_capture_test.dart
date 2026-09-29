// The stored-unread SpO2 candidate column — persistence contract.
//
// `spo2_candidate_raw` exists so the gen5 band's own SpO2 estimate byte is
// CAPTURED from now on even though nothing may interpret it yet (the encoding
// is not pinned; see Sample.spo2CandidateRaw). These tests pin that the
// column really exists on a fresh open (the off-ladder `_repairOpenSchema`
// path), that a Sample written through the seam reads back byte-identical,
// and that the omitted-when-null write leaves absence — never a zero that
// would claim the band sampled and found nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('the column exists on a fresh open (off-ladder repair path)', () async {
    final db = await LocalDb.instance;
    final cols = await db.rawQuery('PRAGMA table_info(decoded_onehz)');
    expect(
      cols.where((c) => c['name'] == 'spo2_candidate_raw'),
      isNotEmpty,
      reason: '_ensureDecodedOneHzBandFields must hand the column out on '
          'every open, exactly like ts_subsec/band_sleep_state',
    );
  });

  test('a written candidate reads back verbatim through the Sample seam',
      () async {
    final db = await LocalDb.instance;
    // The FFI database is shared across the whole run, so clear the slot
    // first — the test is idempotent against whatever ran before it.
    await db.delete('decoded_onehz', where: 'rec_ts = ?', whereArgs: [924242]);
    await db.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': 924242 * 1000,
      'rec_ts': 924242,
      'counter': 1,
      'hr': 64,
      'spo2_candidate_raw': 97,
    });
    final rows =
        await db.query('decoded_onehz', where: 'rec_ts = ?', whereArgs: [924242]);
    final s = Sample.fromDecodedRow(rows.first);
    expect(s.spo2CandidateRaw, 97, reason: 'the raw byte, unfiltered');
    expect(s.hr, 64);
  });

  test('absence stays NULL — never a zero', () async {
    final db = await LocalDb.instance;
    await db.delete('decoded_onehz', where: 'rec_ts = ?', whereArgs: [924243]);
    await db.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': 924243 * 1000,
      'rec_ts': 924243,
      'counter': 2,
      'hr': 60,
    });
    final rows =
        await db.query('decoded_onehz', where: 'rec_ts = ?', whereArgs: [924243]);
    final s = Sample.fromDecodedRow(rows.first);
    expect(s.spo2CandidateRaw, isNull,
        reason: 'no column value means not-a-gen5-record, not "sampled, '
            'nothing" — the distinction IS the contract');
  });
}
