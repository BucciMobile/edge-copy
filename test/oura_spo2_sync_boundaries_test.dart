// §1 of the third audit: continuation behaviour ACROSS SYNC BOUNDARIES,
// checked on the FINAL STORED OBSERVATIONS — the real adapter, the real
// BandHost, the real database, driven by OuraLink.ingestForTest. Not one
// adapter emission is inspected: every expectation reads the
// `observation` rows the production write path committed.
//
// The TIME CONTRACT under test (open_oura native-decoder.md): an event's
// N samples share the envelope stamp as their LAST second, stepping
// backward by 1 s. ACROSS events there is NO established continuation
// contract — each event keeps its own envelope-derived seconds, and two
// events of one run may collide on a second, where the identity index
// keeps the later write (documented, not hidden).
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/adapters/oura_spo2.dart' show kOuraEvtSpo2;
import 'package:openstrap_protocol/openstrap_protocol.dart'
    show kOuraEvtTimeSync;
import 'package:openstrap_edge/ble/oura_link.dart';
import 'package:openstrap_edge/data/db.dart';

const String _deviceId = 'oura-spo2-runs';
final List<int> _key = [
  for (var i = 0; i < 16; i++) 0x10 + i,
];
const int _nowSec = 1786000000;

List<int> _hex(String s) => [
      for (var i = 0; i + 1 < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ];

List<int> _frame(int tag, List<int> payload) =>
    <int>[tag, payload.length, ...payload];

List<int> _event(int tag, int tsDs, List<int> body) => _frame(tag, <int>[
      tsDs & 0xff,
      (tsDs >> 8) & 0xff,
      (tsDs >> 16) & 0xff,
      (tsDs >> 24) & 0xff,
      ...body,
    ]);

final List<int> _nonceReply =
    _frame(0x2f, _hex('2c') + _hex('0e2d6a0a08c99b4365f458e6e97382'));
final List<int> _authOk = _frame(0x2f, _hex('2e00'));

List<int> _summary(int received, int bytesLeft) => _frame(0x11, <int>[
      received,
      0,
      bytesLeft & 0xff,
      (bytesLeft >> 8) & 0xff,
      (bytesLeft >> 16) & 0xff,
      (bytesLeft >> 24) & 0xff,
    ]);

List<int> _syncBody(int unix) => <int>[
      unix & 0xff,
      (unix >> 8) & 0xff,
      (unix >> 16) & 0xff,
      (unix >> 24) & 0xff,
    ];

/// A ring that serves [batches] in order, one per history request.
List<List<int>> Function(int, List<int>) _ring(
    List<List<List<int>>> batches) {
  var served = 0;
  return (int i, List<int> v) {
    if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
    if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
    if (v.first != 0x10) return const <List<int>>[];
    if (served >= batches.length) return [_summary(0, 0)];
    return batches[served++];
  };
}

/// One full sync through the REAL adapter, host and database.
Future<List<Map<String, Object?>>> _sync(
    List<List<List<int>>> batches) async {
  await OuraLink.instance.ingestForTest(
    _deviceId,
    _key,
    _ring(batches),
    nowSeconds: () => _nowSec,
  );
  final db = await LocalDb.instance;
  return db.query('observation',
      where: "vendor_key = 'spo2'",
      orderBy: 'ts_ms, value');
}

/// The stored SpO2 rows as (ts_ms, value), deduplicated by identity.
List<(int, num)> _pairs(List<Map<String, Object?>> rows) => [
      for (final r in rows)
        ((r['ts_ms'] as num).toInt(), (r['value'] as num)),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'oura_spo2_runs_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
    // The pairing row the gate reads.
    final db = await LocalDb.instance;
    await db.insert('device', {
      'id': _deviceId,
      'first_seen': _nowSec * 1000,
      'last_seen': _nowSec * 1000,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });
  tearDown(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  // Anchor: ds=400 -> unix 1782043215. Envelope stamp = LAST sample's
  // second; samples run backward from it.
  const anchor = (400, 1782043215);

  test('within one batch: samples run BACKWARD from the envelope stamp',
      () async {
    final rows = await _sync([
      [
        _event(kOuraEvtSpo2, 400, [0x01, 90, 91, 92, 0xff]),
        _event(kOuraEvtTimeSync, anchor.$1, _syncBody(anchor.$2)),
        _summary(2, 0),
      ]
    ]);
    // Three samples, stamp is the LAST second: 213, 214, 215.
    expect(_pairs(rows), [
      (1782043213000, 90),
      (1782043214000, 91),
      (1782043215000, 92),
    ]);
  });

  test('continuation across two batches of one connection: each event '
      'keeps its own envelope seconds; the replay collapses', () async {
    // Batch 1: the continuing event; batch 2: the closing event AND a
    // replay of the first. Whatever seconds the second event claims, the
    // stored set must be exactly the union of both events'
    // envelope-derived seconds — a replay may never add a second copy.
    final b1 = [
      _event(kOuraEvtSpo2, 400, [0x01, 90, 90, 90, 0xff]),
      _event(kOuraEvtTimeSync, anchor.$1, _syncBody(anchor.$2)),
      _summary(2, 64),
    ];
    final b2 = [
      _event(kOuraEvtSpo2, 400, [0x01, 90, 90, 90, 0xff]),
      _event(kOuraEvtSpo2, 500, [0x01, 91, 91]),
      _summary(2, 0),
    ];
    final rows = await _sync([b1, b2]);
    final pairs = _pairs(rows);
    // The first event's three seconds, once; the closing event's two.
    expect(pairs.where((p) => p.$2 == 90), hasLength(3));
    expect(pairs.where((p) => p.$2 == 91), hasLength(2));
    // No second occupies two rows.
    final stamps = pairs.map((p) => p.$1).toSet();
    expect(stamps, pairs.map((p) => p.$1).toList());
  });

  test('app/adapter restart mid-run: the later sync delivers the closing '
      'event; earlier rows survive, no re-timing', () async {
    // First sync (its own ingestForTest session): the continuing event.
    await _sync([
      [
        _event(kOuraEvtSpo2, 400, [0x01, 90, 90, 90, 0xff]),
        _event(kOuraEvtTimeSync, anchor.$1, _syncBody(anchor.$2)),
        _summary(2, 0),
      ]
    ]);
    // "Restart": a fresh session (fresh adapter, same anchor from the
    // cursor store) delivers the closing event.
    await OuraLink.instance.ingestForTest(
      _deviceId,
      _key,
      _ring([
        [
          _event(kOuraEvtTimeSync, anchor.$1, _syncBody(anchor.$2)),
          _event(kOuraEvtSpo2, 500, [0x01, 91, 91, 91]),
          _summary(2, 0),
        ]
      ]),
      nowSeconds: () => _nowSec,
    );
    final db = await LocalDb.instance;
    final rows = await db.query('observation',
        where: "vendor_key = 'spo2'", orderBy: 'ts_ms');
    final pairs = _pairs(rows);
    expect(pairs.where((p) => p.$2 == 90), hasLength(3));
    expect(pairs.where((p) => p.$2 == 91), hasLength(3));
  });

  test('an invalid event INSIDE a continuing run is refused whole and '
      'shifts nothing', () async {
    // A valid continuing event, then an over-100 event (refused whole),
    // then a valid closing event. The refused event's absence must not
    // move the closing event's seconds — every event keeps its own
    // envelope-derived stamps regardless of its neighbours.
    final rows = await _sync([
      [
        _event(kOuraEvtSpo2, 400, [0x01, 90, 90, 0xff]),
        _event(kOuraEvtSpo2, 410, [0x01, 101, 91, 91]),
        _event(kOuraEvtSpo2, 420, [0x01, 92, 92]),
        _event(kOuraEvtTimeSync, anchor.$1, _syncBody(anchor.$2)),
        _summary(4, 0),
      ]
    ]);
    final pairs = _pairs(rows);
    // The refused event contributed nothing; the others kept their own
    // envelope seconds (420 is +2 s past the anchor event at 400).
    expect(pairs.where((p) => p.$2 == 90), hasLength(2));
    expect(pairs.where((p) => p.$2 == 92), hasLength(2));
    expect(pairs.where((p) => p.$2 == 91), isEmpty);
    // The excluded middle shifted NO stamp: the closing event's seconds
    // are its own, exactly where its envelope puts them.
    final s92 = pairs.where((p) => p.$2 == 92).map((p) => p.$1).toList();
    expect(s92, [1782043216000, 1782043217000]);
  });

  test('a new ring boot (future time_sync) re-anchors; the rows before '
      'it survive with their own stamps', () async {
    // Batch 1 anchored at ds=400; batch 2 carries a LATER time_sync
    // (the ring rebooted and re-set its clock) plus a new event.
    final rows = await _sync([
      [
        _event(kOuraEvtSpo2, 400, [0x01, 90, 90]),
        _event(kOuraEvtTimeSync, 400, _syncBody(1782043215)),
        _summary(2, 64),
      ],
      [
        _event(kOuraEvtSpo2, 500, [0x01, 95, 95]),
        _event(kOuraEvtTimeSync, 500, _syncBody(1782099215)),
        _summary(2, 0),
      ],
    ]);
    final pairs = _pairs(rows);
    // The first event's seconds under the OLD anchor are untouched.
    expect(pairs.where((p) => p.$2 == 90),
        [1782043214000, 1782043215000].map((ms) => anything));
    expect(
      pairs.where((p) => p.$2 == 90).map((p) => p.$1).toSet(),
      {1782043214000, 1782043215000},
    );
    // The new event stamps under the NEW anchor (ds=500 -> 1782099215).
    expect(
      pairs.where((p) => p.$2 == 95).map((p) => p.$1).toSet(),
      {1782099214000, 1782099215000},
    );
  });

  test('an independent series after a CLOSED run never inherits the '
      'earlier run\'s timing', () async {
    // A closed run (no 0xff), then a second, independent event whose
    // envelope stamp equals the first's plus one decisecond. Each event
    // keeps its own seconds; a shared second collapses to one row with
    // the later delivery's value — the documented collision contract.
    final rows = await _sync([
      [
        _event(kOuraEvtSpo2, 400, [0x01, 90, 90, 90]),
        _event(kOuraEvtSpo2, 410, [0x01, 95]),
        _event(kOuraEvtTimeSync, anchor.$1, _syncBody(anchor.$2)),
        _summary(3, 0),
      ]
    ]);
    final pairs = _pairs(rows);
    // The first event: three seconds ending at the stamp.
    expect(
      pairs.where((p) => p.$2 == 90).map((p) => p.$1).toSet(),
      {1782043213000, 1782043214000, 1782043215000},
    );
    // The independent event at ds=410 (+1 s): its single sample is at
    // its own stamp — 1782043216000 — NOT at the first run's last second.
    expect(pairs.where((p) => p.$2 == 95).single.$1, 1782043216000);
  });
}
