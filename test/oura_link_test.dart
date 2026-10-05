// The Oura HOST: scripted frames in, `raw_archive` / `decoded_onehz` out.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a ring (owner
// ruling R6) and `flutter_blue_plus` has no simulator path, so the ring below
// is a script and the frames are hand-built to the layouts the protocol package's
// Oura wire format documents. It pins the HOST — the anchor, the commit ordering, the
// attribution and what is refused — and it proves nothing about a real ring.
//
// `oura_adapter_test.dart` already proves the session state machine. This file
// exists for the three things only a host can get wrong: banking every byte,
// refusing to stamp a second it cannot honestly name, and never putting a
// command on the wire that no builder produced.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart'
    show ReplayBandLink;
import 'package:openstrap_edge/ble/oura_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'oura-0a1b2c3d';

/// Any 16 bytes. The replay ring answers a scripted result rather than actually
/// verifying the AES block, so the VALUE of the key is not what is under test
/// here — `oura_adapter_test.dart` pins the cipher against a known vector.
const List<int> _key = <int>[
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
];

/// The session's "now". Fixed so a stamp assertion is a real assertion.
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

List<int> _summary(int received, int bytesLeft) => _frame(0x11, <int>[
      received,
      0,
      bytesLeft & 0xff,
      (bytesLeft >> 8) & 0xff,
      (bytesLeft >> 16) & 0xff,
      (bytesLeft >> 24) & 0xff,
    ]);

final List<int> _nonceReply =
    _frame(0x2f, _hex('2c') + _hex('0e2d6a0a08c99b4365f458e6e97382'));
final List<int> _authOk = _frame(0x2f, _hex('2e00'));

/// 0x0d6c centi-degrees = 34.36 C, a plausible worn reading.
const String _temp3436 = '6c0d';

/// A time_sync body: Unix seconds, little-endian.
List<int> _syncBody(int unix) => <int>[
      unix & 0xff,
      (unix >> 8) & 0xff,
      (unix >> 16) & 0xff,
      (unix >> 24) & 0xff,
    ];

/// A ring that serves [batches] in order, one per history request, then stops.
List<List<int>> Function(int, List<int>) _ring(List<List<List<int>>> batches) {
  var served = 0;
  return (int i, List<int> v) {
    if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
    if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
    if (v.first != 0x10) return const <List<int>>[];
    if (served >= batches.length) return [_summary(0, 0)];
    return batches[served++];
  };
}

Future<ReplayBandLinkResult> _run(List<List<List<int>>> batches) async {
  final link = await OuraLink.instance.ingestForTest(
    _deviceId,
    _key,
    _ring(batches),
    nowSeconds: () => _nowSec,
  );
  final db = await LocalDb.instance;
  return ReplayBandLinkResult(
    writes: [for (final w in link.writes) w.$2],
    onehz: await db.query('decoded_onehz', orderBy: 'ts_ms'),
    archive: await db.query('raw_archive', orderBy: 'captured_at, hex'),
  );
}

class ReplayBandLinkResult {
  final List<List<int>> writes;
  final List<Map<String, Object?>> onehz;
  final List<Map<String, Object?>> archive;
  const ReplayBandLinkResult({
    required this.writes,
    required this.onehz,
    required this.archive,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'oura_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('every frame is banked verbatim, decoded or not', () async {
    const unknown = '0102030405060708090a0b0c0d0e';
    final r = await _run([
      [
        _event(kOuraEvtTimeSync, 1000, _syncBody(1782043215)),
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        // Nothing decodes this one. It must still reach the archive — the beat
        // intervals and the hypnogram live in frames exactly like it.
        _event(0x60, 1300, _hex(unknown)),
        _summary(3, 0),
      ],
    ]);
    expect(r.archive, hasLength(3));
    final hexes = r.archive.map((a) => a['hex']).toSet();
    expect(hexes.contains(_hexOf(_event(0x60, 1300, _hex(unknown)))), isTrue);
    // One reason PER TAG, so a decoder written later finds its records by name.
    expect(
      r.archive.map((a) => a['reason']).toSet(),
      {'oura_evt_0x42', 'oura_evt_0x69', 'oura_evt_0x60'},
    );
    // NOT re-drivable, and that is deliberate: `redriveArchivedRecords` replays
    // a row's hex through the WHOOP R24 chain, which would be the wrong decoder
    // over the right bytes.
    for (final a in r.archive) {
      expect(LocalDb.redrivableArchiveReasons, isNot(contains(a['reason'])));
    }
  });

  test('a measured time_sync is what stamps the batch carrying it', () async {
    const syncUnix = 1782043215;
    final r = await _run([
      [
        _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix)),
        // 200 deciseconds — 20 seconds — after the sync.
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        _summary(2, 0),
      ],
    ]);
    expect(r.onehz, hasLength(1));
    expect(r.onehz.first['rec_ts'], syncUnix + 20);
    expect(r.onehz.first['ts_ms'], (syncUnix + 20) * 1000);
    expect(r.onehz.first['skin_temp_c'], closeTo(34.36, 0.001));
    // Absolute Celsius NEVER lands in the relative-ADC column, and a ring
    // second that carried a temperature carried no heart rate.
    expect(r.onehz.first['skin_temp_raw'], isNull);
    expect(r.onehz.first['hr'], isNull);
    for (final c in ['ax', 'ay', 'az', 'spo2_red_raw']) {
      expect(r.onehz.first[c], isNull, reason: c);
    }
    // Attributed, and not the primary band.
    expect(r.onehz.first['device_id'], _deviceId);
    expect(r.onehz.first['device_id'], isNot(LocalDb.kPrimaryDeviceId));
    expect(r.onehz.first['source'], 'oura');
    expect(r.onehz.first['device_family'], 'oura');
  });

  test('the anchor and the cursor both survive the session', () async {
    const syncUnix = 1782043215;
    await _run([
      [
        _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix)),
        _summary(1, 0),
      ],
    ]);
    expect(await LocalDb.getCursor('oura_anchor:$_deviceId'), '1000,$syncUnix');
    // The highest envelope stamp in the batch plus one — the short-batch
    // advance. Persisted only because the commit landed first.
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 1001);
  });

  test('no anchor anywhere writes no timestamped row, and banks the bytes',
      () async {
    // THE HONEST ABSTENTION. A plausible wrong `ts_ms` is worse than a missing
    // one: it writes the same physiological second under a second key that
    // REPLACE can never collapse.
    final r = await _run([
      [
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        _summary(1, 0),
      ],
    ]);
    expect(r.onehz, isEmpty);
    expect(r.archive, hasLength(1));
    expect(await LocalDb.getCursor('oura_anchor:$_deviceId'), isNull);
  });

  test('a reading held before the anchor arrives is written once it does',
      () async {
    // Every connect writes SET_TIME, so the ring's fresh `time_sync` lands at
    // its CURRENT decisecond — the END of the drain. On a fresh pairing that is
    // after the whole of its history, and abstaining would throw all of it away.
    const syncUnix = 1782043215;
    final r = await _run([
      [
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        _summary(1, 512),
      ],
      [
        // 100 deciseconds — 10 seconds — after the reading above.
        _event(kOuraEvtTimeSync, 1300, _syncBody(syncUnix)),
        _summary(1, 0),
      ],
    ]);
    expect(r.onehz, hasLength(1));
    expect(r.onehz.first['rec_ts'], syncUnix - 10);
  });

  test('a stored anchor stamps a session that measures none', () async {
    const storedUnix = 1782043215;
    await LocalDb.setCursor('oura_anchor:$_deviceId', '1000,$storedUnix');
    final r = await _run([
      [
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        _summary(1, 0),
      ],
    ]);
    expect(r.onehz, hasLength(1));
    expect(r.onehz.first['rec_ts'], storedUnix + 20);
  });

  test('a stamp in the future is refused, not written', () async {
    // The reboot direction that CAN be bounded for free: the ring's decisecond
    // counter is an uptime, so a stale origin extrapolates a record forward
    // past now — and no record is from the future.
    await LocalDb.setCursor('oura_anchor:$_deviceId', '0,$_nowSec');
    final r = await _run([
      [
        _event(kOuraEvtTempPeriod, 10000000, _hex(_temp3436)),
        _summary(1, 0),
      ],
    ]);
    expect(r.onehz, isEmpty, reason: 'a million seconds from now');
    expect(r.archive, hasLength(1), reason: 'still banked, just not stamped');
  });

  test('the host writes nothing that no builder produced', () async {
    // ASSUMPTIONS I1: `GattBandLink`'s dangerous-opcode block reads an opcode
    // out of a WHOOP envelope and answers null for an unframed band, so NOTHING
    // at the link refuses these. The ring has a factory reset, a DFU state
    // machine, a flight mode, a manufacturing-mode setter and a bulk-sampler
    // erase, and the only thing stopping them is that no builder exists and
    // this host writes nothing else.
    final r = await _run([
      [
        _event(kOuraEvtTimeSync, 1000, _syncBody(1782043215)),
        _event(kOuraEvtDebugData, 1100, _hex('2456c80f00')),
        _summary(2, 0),
      ],
    ]);
    expect(r.writes, isNotEmpty);
    // The four builders in the protocol package's Oura wire format, and nothing
    // else — a new tag here means someone added a builder, go and read which one.
    const built = {0x2f, 0x1c, 0x12, 0x10};
    for (final w in r.writes) {
      expect(built, contains(w.first),
          reason: 'unbuilt command tag 0x${w.first.toRadixString(16)}');
    }
    // And each write is byte-identical to what its builder produces.
    for (final w in r.writes) {
      final rebuilt = switch (w.first) {
        0x2f when w[2] == 0x2b => ouraCmdAuthNonce(),
        0x2f => ouraCmdAuthenticate(w.sublist(3)),
        0x1c => ouraCmdSetNotifyFlags(w[2]),
        0x12 => ouraCmdSyncTime(
            w[2] | (w[3] << 8) | (w[4] << 16) | (w[5] << 24),
            tzHalfHours: w[10],
          ),
        _ => ouraCmdGetEvents(
            w[2] | (w[3] << 8) | (w[4] << 16) | (w[5] << 24),
            maxEvents: w[6],
          ),
      };
      expect(w, rebuilt);
    }
  });

  test('the stranded reset still lands when an advance is queued ahead of it',
      () async {
    // Batch 1 advances the cursor, batch 2 is stranded; the reset is queued
    // behind the advance and must still be the write that lands.
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '5000');
    await OuraLink.instance.ingestForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first != 0x10) return const <List<int>>[];
        final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
        if (cursor == 5000) {
          return [
            _event(kOuraEvtTimeSync, 5000, _syncBody(1782043215)),
            _event(kOuraEvtTempPeriod, 5100, _hex(_temp3436)),
            _summary(2, 512),
          ];
        }
        return [_summary(0, 4096)];
      },
      nowSeconds: () => _nowSec,
    );
    // The reset landed despite the advance queued ahead of it.
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 0);
  });

  test('a stranded reset invalidates the stored time anchor too', () async {
    // The anchor was measured on the boot the reset ended.
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '5000');
    await LocalDb.setCursor('oura_anchor:$_deviceId', '4000,1782043215');
    await OuraLink.instance.ingestForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 4096)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 0);
    expect(await LocalDb.getCursor('oura_anchor:$_deviceId'), isNull,
        reason: 'the anchor was measured on the boot the reset ended');
  });

  test('the band-only readers cannot see a ring row', () async {
    await _run([
      [
        _event(kOuraEvtTimeSync, 1000, _syncBody(1782043215)),
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        _summary(2, 0),
      ],
    ]);
    final db = await LocalDb.instance;
    final banded = await db.rawQuery(
      'SELECT COUNT(*) c FROM decoded_onehz WHERE source IS NULL',
    );
    expect(banded.first['c'], 0,
        reason: 'every derive/export read filters `source IS NULL`');
  });

  test('a bookmark past the end of the ring is dropped, not kept', () async {
    // The ring rebooted: its decisecond counter restarted below our bookmark,
    // so every request from there matches nothing while it quietly fills up.
    // Bytes remaining with nothing delivered is the signal, and the remedy is
    // to re-read from the beginning — free, because a re-read is idempotent.
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '9391523');
    await OuraLink.instance.ingestForTest(_deviceId, _key, (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) return [_summary(0, 4096)];
      return const <List<int>>[];
    }, nowSeconds: () => _nowSec);
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 0);
  });

  test('an empty ring keeps its bookmark', () async {
    // The other half of the same signal, and getting it wrong costs a full
    // re-read on every idle sync: no bytes left and nothing delivered is a ring
    // with nothing to give, not a stranded bookmark.
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '9391523');
    await OuraLink.instance.ingestForTest(_deviceId, _key, (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) return [_summary(0, 0)];
      return const <List<int>>[];
    }, nowSeconds: () => _nowSec);
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 9391523);
  });

  test('the key install is one frame, the key in the clear, 16 bytes', () {
    // It cannot be authenticated — it is what creates the credential the
    // handshake uses — so the whole of its safety is that a ring only accepts
    // one while it is factory reset.
    final frame = ouraCmdSetAuthKey(_key);
    expect(frame.first, 0x24);
    expect(frame[1], 16, reason: 'length counts payload bytes only');
    expect(frame.sublist(2), _key);
    expect(frame, hasLength(18));
    // A short or long key is a caller bug, not something to pad around: the
    // ring would latch whatever it was sent and only a factory reset undoes it.
    expect(() => ouraCmdSetAuthKey(const <int>[1, 2, 3]), throwsArgumentError);
    // Success is status 0; anything else, and silence, is a refusal.
    expect(ouraSetAuthKeyResult(parseOuraFrame(<int>[0x25, 0x01, 0x00])!), 0);
    expect(ouraSetAuthKeyResult(parseOuraFrame(<int>[0x25, 0x01, 0x02])!), 2);
    expect(ouraSetAuthKeyResult(parseOuraFrame(<int>[0x11, 0x01, 0x00])!), isNull);
  });

  test('nothing paired means nothing to sync', () async {
    expect(await OuraLink.pairedRingRow(), isNull);
    expect(await OuraLink.instance.sync(), isFalse);
  });

  test('a ring that answers below the bookmark never moves it', () async {
    // Replays below the bookmark must not move it backwards.
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '5000');
    await OuraLink.instance.ingestForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          return [
            _event(kOuraEvtTimeSync, 4900, _syncBody(1782043215)),
            _event(kOuraEvtTempPeriod, 4999, _hex(_temp3436)),
            _summary(2, 0),
          ];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 5000);
  });

  test('a rebooted ring whose tail stops short of the bookmark resets it',
      () async {
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '5000');
    await OuraLink.instance.ingestForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          return [
            _event(kOuraEvtTimeSync, 4000, _syncBody(1782043215)),
            _event(kOuraEvtTempPeriod, 4100, _hex(_temp3436)),
            _summary(2, 0),
          ];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 0);
  });

  test('a drain that reaches the end reports the session as synced', () async {
    // An empty, up-to-date ring is a SUCCESSFUL sync — the honest end of a
    // drain, with no measurement invented. The expectation is on the SAME
    // bool `sync()` returns: `_replaySession` runs `_runSession`, the
    // production result path, so this pins the `return true` a user's
    // "Synced." snackbar is built on.
    final ok = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 0)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    expect(ok, isTrue);
  });

  test('a refused authentication reports the session as NOT synced', () async {
    // Auth-Abbruch: the ring answers the challenge with a refusal. Nothing
    // was fetched, so `sync()` must say so — not "Synced.".
    final ok = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) {
          return [_frame(0x2f, _hex('2e01'))];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      timeouts: const Duration(milliseconds: 50),
    );
    expect(ok, isFalse);
  });

  test('a drain that never gets its batch reports the session as NOT synced',
      () async {
    // The ring authenticates and then goes quiet: the history request is
    // never answered. Connected, but nothing was synced — `sync()` must say
    // so rather than report "Synced.", which is the exact symptom a user
    // sees as "the ring connects but no data arrives".
    final ok = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        // 0x1c (notify flags), 0x12 (time sync) and 0x10 (history) all go
        // unanswered; the session ends on the reply window, not on data.
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      timeouts: const Duration(milliseconds: 50),
    );
    expect(ok, isFalse);
  });

  test('success then failure across two consecutive attempts', () async {
    // The result flag must be PER SESSION, not a sticky latch: a successful
    // first sync must not make a second, failed one report success — the
    // §4.3 sticky-boolean pattern this repo keeps shipping.
    final first = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 0)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    expect(first, isTrue);
    final second = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      timeouts: const Duration(milliseconds: 50),
    );
    expect(second, isFalse);
  });

  test('a refused write reports the session as NOT synced', () async {
    // Verweigerter Write: the ring refuses the nonce request (flat battery,
    // wedged stack). The session ends on the adapter's own `return false`
    // path — `_authenticate` refuses to carry on unauthenticated — so the
    // result must be false, not "Synced.".
    final ok = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) => const <List<int>>[],
      nowSeconds: () => _nowSec,
      writeSucceeds: false,
    );
    expect(ok, isFalse);
  });

  test('a failed durable commit reports the session as NOT synced', () async {
    // Echter Commit-Fehler, nicht nur ein ausbleibendes Confirm: der Host
    // läuft gegen die produktionsseitige Guard-Assertion in
    // `commitSyncBatch` (neutrale Zeilen unter der primären Device-Id), die
    // INNERHALB der echten Transaktion wirft. `BandHost._commitLocked`
    // behandelt jede Exception als Commit-Fehler und puffert zurück, also
    // steht diese Assertion modellhaft für jeden Transaktionsfehler.
    //
    // GRENZE DIESER INJEKTION: die öffentliche `sync()`-Methode verweigert
    // die primäre Device-Id bereits VOR jeder Session (`_sync`'s guard). Der
    // Test erreicht den tieferen In-Transaction-Fehler über die Test-Seam.
    // Es existiert keine produktionsseitige Fault-Injection an `LocalDb`
    // für einen Speicherfehler unter zulässiger Oura-Device-ID; ein solches
    // Seam wäre ein Refactoring, das über diesen Test hinausginge.
    //
    // DAS CONFIRM IST NUR INDIREKT BEOBACHTBAR: das Protokoll hat keinen
    // ACK-Write — `OffloadCheckpoint.confirm()` ist ein reiner interner
    // Rückruf. Der einzige wire-sichtbare Nachweis eines BESTÄTIGTEN Batches
    // ist der zweite History-Request, und der passiert NUR bei
    // `bytesLeft > 0` (Adapter-Schleife). Deshalb meldet dieser Batch Bytes
    // als verbleibend: nach einem bestätigten Commit MÜSSTE der Adapter
    // erneut anfragen; nach einem fehlgeschlagenen Commit bleibt jeder
    // weitere Write aus. Der Kontrollfall im nächsten Test zeigt, dass die
    // Assertion die beiden Verläufe wirklich unterscheidet.
    await LocalDb.setCursor(
        'oura_anchor:${LocalDb.kPrimaryDeviceId}', '1000,1782043215');
    final ok = await OuraLink.instance.syncResultForTest(
      LocalDb.kPrimaryDeviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          // Ein Batch mit verbleibenden Daten: nur ein BESTÄTIGTES Confirm
          // führt zum zweiten History-Request.
          return [
            _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
            _summary(1, 4096),
          ];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      timeouts: const Duration(milliseconds: 50),
    );
    expect(ok, isFalse, reason: 'the commit failed — no durable data, no '
        'confirm, so no success');
    final link = OuraLink.instance.lastReplayLink!;
    // KEIN ZWEITER HISTORY-REQUEST: das Confirm lief nie, also blieb jeder
    // weitere Write aus. (Ein bestätigter Batch MIT bytesLeft > 0 hätte
    // zwingend einen zweiten 0x10-Write erzeugt — siehe Kontrollfall.)
    final writes = [for (final w in link.writes) w.$2];
    expect(writes.where((w) => w.first == 0x10), hasLength(1),
        reason: 'the failed commit must end the session before the loop '
            'asks again');
    // Cursor nie bewegt: die Cursor-Note feuert nur nach bestätigtem Batch.
    expect(
      await LocalDb.getCursorInt('oura_cursor_ds:${LocalDb.kPrimaryDeviceId}'),
      isNull,
    );
    // Nichts aus der fehlgeschlagenen Transaktion erreichte die Tabelle.
    final db = await LocalDb.instance;
    expect(
      await db.query('decoded_onehz',
          where: 'device_id = ?', whereArgs: [LocalDb.kPrimaryDeviceId]),
      isEmpty,
    );
  });

  test('a confirmed batch with bytes left DOES ask again (control case)',
      () async {
    // KONTROLLFALL: dieselbe Ring-Antwort (1 Event, bytesLeft > 0) unter
    // einer ZULÄSSIGEN Oura-Device-ID mit erfolgreichem Commit. Der Adapter
    // MUSS hier den zweiten History-Request stellen — erst damit ist die
    // Single-Request-Assertion des Fehlertests ein echter Nachweis, dass
    // das Confirm unterblieb, und nicht nur die normale Endsequenz eines
    // abschließenden Batches.
    await LocalDb.setCursor('oura_anchor:$_deviceId', '1000,1782043215');
    var batches = 0;
    final ok = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          batches++;
          if (batches == 1) {
            return [
              _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
              _summary(1, 4096),
            ];
          }
          return [_summary(0, 0)];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    // Die Session endet hier erst im zweiten Durchlauf (zweiter Batch:
    // summary(0,0) → drain ok) — Ergebnis true, und es gab mehr als einen
    // History-Request: der Nachweis des Confirms.
    expect(ok, isTrue);
    final link = OuraLink.instance.lastReplayLink!;
    final writes = [for (final w in link.writes) w.$2];
    expect(writes.where((w) => w.first == 0x10).length, greaterThan(1),
        reason: 'the confirmed batch advanced the loop — this is the '
            'behaviour the failed-commit test proves was MISSING');
    // Und der Cursor ist tatsächlich gewachsen.
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 1201);
  });

  group('session lifecycle (the production outer order)', () {
    test('cleanup waits for a successful session, then runs', () async {
      // VOLLE HANDSHAKE-STEUERUNG, keine Scheduler-Zufälligkeit: der
      // Beobachter läuft von Beginn an, und jede Ring-Antwort wird erst
      // gefüttert, NACHDEM der zugehörige Write beobachtet wurde — die
      // Completer werden synchron in `onWrite` abgeschlossen.
      final nonceAsked = Completer<void>();
      final proofAsked = Completer<void>();
      final historyAsked = Completer<void>();
      final (result, link) = await OuraLink.instance.startSessionForTest(
        _deviceId,
        _key,
        nowSeconds: () => _nowSec,
        onWrite: (uuid, value) {
          if (value.first == 0x2f && value[2] == 0x2b) {
            if (!nonceAsked.isCompleted) nonceAsked.complete();
          } else if (value.first == 0x2f && value[2] == 0x2d) {
            if (!proofAsked.isCompleted) proofAsked.complete();
          } else if (value.first == 0x10) {
            if (!historyAsked.isCompleted) historyAsked.complete();
          }
        },
      );
      // Nonce-Anfrage beobachtet → mit der Challenge antworten.
      await nonceAsked.future;
      link.feed(kOuraNotifyChar, _nonceReply, atSec: _nowSec);
      // Proof-Write beobachtet → der Ring akzeptiert den Schlüssel.
      await proofAsked.future;
      link.feed(kOuraNotifyChar, _authOk, atSec: _nowSec);
      // History-Anfrage beobachtet → die Antwort ZURÜCKHALTEN.
      await historyAsked.future;
      // OFFENE SESSION: das Cleanup darf noch nicht begonnen haben.
      // GENAU HIER FÄNGT DIESEN TEST EIN VORZEITIGES TEARDOWN IN
      // `_runSessionAndTeardown` selbst (ein `finally`, das vor dem
      // Session-Ende läuft): `stop()` hätte den Link bereits geschlossen
      // und das Abonnement gekündigt, während der Drain noch auf seine
      // Antwort wartet.
      // GRENZE: der äußere `_sync`-Rumpf (connect, discovery) ist ohne
      // Radio nicht testbar und hier NICHT abgedeckt.
      expect(link.closed, isFalse, reason: 'teardown must not have begun');
      expect(link.isListening(kOuraNotifyChar), isTrue,
          reason: 'the session still owns the notify subscription');
      var settled = false;
      result.then((_) => settled = true);
      // Ein Mikrotask-Turn, damit sich das `.then` anhängen kann — kein
      // Sleep; die Reihenfolge steht bereits durch die Assertionen oben.
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse,
          reason: 'the session is still open — the result is not settled');

      // Die Abschlussantwort: leer und auf dem neuesten Stand.
      link.feed(kOuraNotifyChar, _summary(0, 0), atSec: _nowSec);
      final ok = await result;
      expect(ok, isTrue);
      // CLEANUP GELAUFEN, nach dem Session-Ende.
      expect(link.closed, isTrue, reason: 'stop() closed the link');
      expect(link.isListening(kOuraNotifyChar), isFalse,
          reason: 'the host cancelled its run subscription on the way out');
    });

    test('cleanup also runs after a failing session', () async {
      // Derselbe äußere Ablauf für den Fehlerpfad. Der Proof-Beobachter ist
      // dieselbe Instanz und lief VOR dem Füttern der Challenge — die
      // Reihenfolge, die der Reviewer verlangt hat.
      final nonceAsked = Completer<void>();
      final proofAsked = Completer<void>();
      final (result, link) = await OuraLink.instance.startSessionForTest(
        _deviceId,
        _key,
        nowSeconds: () => _nowSec,
        onWrite: (uuid, value) {
          if (value.first == 0x2f && value[2] == 0x2b) {
            if (!nonceAsked.isCompleted) nonceAsked.complete();
          } else if (value.first == 0x2f && value[2] == 0x2d) {
            if (!proofAsked.isCompleted) proofAsked.complete();
          }
        },
      );
      await nonceAsked.future;
      link.feed(kOuraNotifyChar, _nonceReply, atSec: _nowSec);
      await proofAsked.future;
      expect(link.closed, isFalse,
          reason: 'the session is still mid-handshake');
      // Die Authentifizierung verweigern: Ergebnis 1 = falscher Schlüssel.
      link.feed(kOuraNotifyChar, _frame(0x2f, _hex('2e01')),
          atSec: _nowSec);
      final ok = await result;
      expect(ok, isFalse);
      expect(link.closed, isTrue,
          reason: 'stop() ran after the failed session ended');
      expect(link.isListening(kOuraNotifyChar), isFalse);
    });

    test('the second stop() of the session path is a harmless no-op',
        () async {
      // `_sync` behält sein äußeres `finally { await stop(); }` für die
      // Early-Returns (Bluetooth aus, fehlende Characteristics) und die
      // Ausnahmepfade — deshalb läuft stop() auf dem Session-Pfad zweimal:
      // einmal in `_runSessionAndTeardown`, einmal im äußeren finally.
      // Dieser Test pinnt, dass der zweite Aufruf sicher ist: kein Wurf,
      // keine Cursor-Korruption, kein Zustandsrest.
      final nonceAsked = Completer<void>();
      final proofAsked = Completer<void>();
      final historyAsked = Completer<void>();
      final (result, link) = await OuraLink.instance.startSessionForTest(
        _deviceId,
        _key,
        nowSeconds: () => _nowSec,
        onWrite: (uuid, value) {
          if (value.first == 0x2f && value[2] == 0x2b) {
            if (!nonceAsked.isCompleted) nonceAsked.complete();
          } else if (value.first == 0x2f && value[2] == 0x2d) {
            if (!proofAsked.isCompleted) proofAsked.complete();
          } else if (value.first == 0x10) {
            if (!historyAsked.isCompleted) historyAsked.complete();
          }
        },
      );
      await nonceAsked.future;
      link.feed(kOuraNotifyChar, _nonceReply, atSec: _nowSec);
      await proofAsked.future;
      link.feed(kOuraNotifyChar, _authOk, atSec: _nowSec);
      await historyAsked.future;
      link.feed(kOuraNotifyChar, _summary(0, 0), atSec: _nowSec);
      expect(await result, isTrue);
      // Der erste stop() lief im Session-Teardown; das hier ist der zweite.
      await OuraLink.instance.stop();
      expect(link.closed, isTrue, reason: 'still closed — no re-open');
      expect(link.isListening(kOuraNotifyChar), isFalse);
    });
  });

  test(
      'a session held open at a CONCRETE step fails the HARNESS, '
      'it does not return false',
      () async {
    // TEST-WATCHDOG: `onTimeout: () => false` alone would let a negative
    // test's `isFalse` expectation pass on a HANG — the exact greenwash the
    // review called out. The wedge here is NOT a 1 ms patience racing
    // execution speed: the session's FIRST write (the auth nonce) parks at
    // a completer the test never completes. The session is genuinely,
    // deterministically stuck mid-handshake — the exact "ring that never
    // answers" the watchdog exists for. `gateEntered` proves the session
    // actually reached the held step BEFORE the watchdog judges it, so the
    // verdict cannot depend on machine speed either way.
    ReplayBandLink? heldLink;
    final ok = OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 0)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      harnessTimeout: const Duration(seconds: 2),
      onLink: (link) {
        heldLink = link;
        link.writeGate = Completer<void>();
      },
    );
    final link = heldLink!;
    // The session reached the held step (its first write parked) ...
    await link.gateEntered;
    // ... and it is stuck there for real: not closed, still subscribed,
    // and no write made it past the gate.
    expect(link.closed, isFalse);
    expect(link.isListening(kOuraNotifyChar), isTrue);
    expect(link.writes, isEmpty,
        reason: 'the held step is the FIRST write — the session is parked '
            'mid-handshake, not past it');
    await expectLater(ok, throwsA(isA<StateError>()));
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('a wedged session cleans up before the harness failure surfaces',
      () async {
    // CLEANUP ON THE TIMEOUT PATH TOO: the watchdog must run the same
    // teardown a normal path would (link closed, host stopped, cursor
    // writes flushed, fields cleared) BEFORE the StateError surfaces, so
    // a wedged session never leaves a half-torn OuraLink behind. Same
    // deterministic wedge as the test above: the first write parks at a
    // completer that is never completed.
    final epochBefore = OuraLink.instance.sessionEpochForTest;
    try {
      await OuraLink.instance.syncResultForTest(
        _deviceId,
        _key,
        (i, v) {
          if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
          if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
          if (v.first == 0x10) return [_summary(0, 0)];
          return const <List<int>>[];
        },
        nowSeconds: () => _nowSec,
        harnessTimeout: const Duration(seconds: 2),
        onLink: (link) => link.writeGate = Completer<void>(),
      );
      fail('the wedged session must have thrown, not returned');
    } on StateError {
      // expected: the harness failure, AFTER cleanup ran
    }
    // Cleanup observables: the wedged session's link was closed by the
    // harness teardown, its fields cleared, and the epoch moved on — the
    // session left no half-torn state behind.
    expect(OuraLink.instance.lastReplayLink!.closed, isTrue,
        reason: 'the harness closed the wedged session\'s link on the '
            'timeout path');
    expect(OuraLink.instance.sessionEpochForTest, greaterThan(epochBefore),
        reason: 'cleanup ran: the harness moved the session state on');
    // A stop() naming an ALREADY-PAST epoch (here: one from before the
    // wedged session even started) must be a no-op. The wedged session's
    // OWN late stop (its epoch is still current — no follow-up has started
    // in this test) is the idempotent double-stop the lifecycle tests
    // already cover; the cross-session case is the next test.
    await OuraLink.instance.stop(epoch: epochBefore);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
      'a late teardown of a PAST session cannot touch a follow-up session '
      'that is STILL OPEN',
      () async {
    // THE SEQUENCE the epoch guard exists for, driven to the letter of
    // the review: attempt 1 wedges (its first write parked at a completer)
    // and its harness gives up on it, but its session body — and with it
    // the `finally { stop(epoch: ...) }` — is still pending. Attempt 2
    // then STARTS and is held open mid-session by a WITHHELD ring reply
    // (the same concrete-step technique the lifecycle tests use). Only
    // then is attempt 1's delayed teardown actually RELEASED, while
    // attempt 2 is open. DURING the overlap: link 2 not closed, its RX
    // subscription alive, its host untouched. Afterwards attempt 2 is
    // completed normally and must succeed.
    // ATTEMPT 1: wedged at its first write; its harness will give up on it.
    final wedgedGate = Completer<void>();
    ReplayBandLink? wedgedLink;
    final firstAttempt = OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 0)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      harnessTimeout: const Duration(seconds: 2),
      onLink: (link) {
        wedgedLink = link;
        link.writeGate = wedgedGate;
      },
    );
    final wedgedEpoch = OuraLink.instance.sessionEpochForTest;
    // ATTEMPT 2: manual-drive, NO gate on its writes — the test holds IT
    // open by withholding ring replies, exactly like the lifecycle tests.
    final nonceAsked = Completer<void>();
    final proofAsked = Completer<void>();
    final historyAsked = Completer<void>();
    final (secondResult, secondLink) =
        await OuraLink.instance.startSessionForTest(
      _deviceId,
      _key,
      nowSeconds: () => _nowSec,
      onWrite: (uuid, value) {
        if (value.first == 0x2f && value[2] == 0x2b) {
          if (!nonceAsked.isCompleted) nonceAsked.complete();
        } else if (value.first == 0x2f && value[2] == 0x2d) {
          if (!proofAsked.isCompleted) proofAsked.complete();
        } else if (value.first == 0x10) {
          if (!historyAsked.isCompleted) historyAsked.complete();
        }
      },
    );
    final secondEpoch = OuraLink.instance.sessionEpochForTest;
    expect(secondEpoch, greaterThan(wedgedEpoch));
    // Attempt 1's harness gives up on the wedged session (StateError) and
    // runs its cleanup; attempt 1's session body stays parked at the gate.
    await expectLater(firstAttempt, throwsA(isA<StateError>()));
    // Drive attempt 2 INTO its held step: the nonce write went out (proof
    // the session is driving the link), and the test withholds the reply.
    await nonceAsked.future;
    // ATTEMPT 2 IS NOW OPEN MID-HANDSHAKE: not closed, subscribed, no
    // teardown begun. Record the state the late teardown must not touch.
    expect(secondLink.closed, isFalse,
        reason: 'attempt 2 is mid-handshake — its own teardown is far away');
    expect(secondLink.isListening(kOuraNotifyChar), isTrue,
        reason: 'attempt 2 owns a live RX subscription');
    final hostBefore = OuraLink.instance.hostForTest;
    // NOW RELEASE attempt 1's delayed teardown — attempt 2 still open.
    wedgedGate.complete();
    // Attempt 1's unwind after the release is a pure in-memory microtask
    // chain: the released write returns false (its link was closed by the
    // harness — the close contract at work), `_authenticate` returns
    // false, `run()` ends, `_runSession` returns, and the `finally` runs
    // `stop(epoch: wedgedEpoch)` — the LATE teardown, attempt 2 open.
    // There is deliberately no completion to await: the guard makes the
    // late stop a NO-OP, and a no-op leaves no trace — that is exactly
    // what the assertions below verify. The settle window is bounded and
    // orders of magnitude longer than the microtask chain needs; if the
    // late stop is UNGUARDED (the regression), it nulls `_host` during
    // this window and the `same(hostBefore)` assertion fails.
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    // THE OVERLAP VERDICT — attempt 2 was open the whole time attempt 1's
    // late teardown ran, and nothing it touched changed:
    expect(secondLink.closed, isFalse,
        reason: 'a late teardown of a PAST session must not close the '
            'follow-up session\'s link');
    expect(secondLink.isListening(kOuraNotifyChar), isTrue,
        reason: 'a late teardown of a PAST session must not cancel the '
            'follow-up session\'s RX subscription');
    expect(OuraLink.instance.hostForTest, same(hostBefore),
        reason: 'a late teardown of a PAST session must not stop or '
            'replace the follow-up session\'s host');
    // NOW complete attempt 2 normally: feed the withheld handshake, each
    // reply after its write was observed — completer-driven, no sleeps.
    secondLink.feed(kOuraNotifyChar, _nonceReply, atSec: _nowSec);
    await proofAsked.future;
    secondLink.feed(kOuraNotifyChar, _authOk, atSec: _nowSec);
    await historyAsked.future;
    secondLink.feed(kOuraNotifyChar, _summary(0, 0), atSec: _nowSec);
    final ok2 = await secondResult;
    expect(ok2, isTrue,
        reason: 'the follow-up session must succeed on its own terms, '
            'untouched by the past session\'s late teardown');
    expect(secondLink.closed, isTrue,
        reason: 'its OWN teardown closed it — not the past session\'s');
    expect(secondLink.isListening(kOuraNotifyChar), isFalse);
    expect(OuraLink.instance.sessionEpochForTest, secondEpoch);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('a closed replay link refuses new writes', () async {
    // THE CLOSE CONTRACT, EXACTLY AS SPECIFIED: a new write after close
    // returns false and is NOT recorded. The check runs BEFORE onWrite
    // and BEFORE the writes list — a write an adapter attempted past its
    // teardown must leave no trace that could read as a real session write
    // or fire an observer that assumes a live session.
    final link = ReplayBandLink();
    await link.close();

    final accepted = await link.write(
      kOuraCommandChar,
      <int>[0x10],
    );

    expect(accepted, isFalse);
    expect(link.writes, isEmpty);
  });

  test('a replay write parked at a GATE is refused when close beats it',
      () async {
    // THE SEPARATE CASE the review demanded, on the EXISTING gate seam
    // (no wall-clock delays racing execution speed): a write that was
    // ACCEPTED before close but is still parked at an await boundary must
    // not report success once the link has closed underneath it.
    // NOT a claim that a GATT platform write behaves identically — the
    // real link's refusal is checked inside its write chain, before the
    // operation is handed to the plugin; what this pins is the CONTRACT
    // (a closed link never reports success for a write that lands after
    // close), which the replay link and the real link must both honour,
    // each in its own implementation.
    final gate = Completer<void>();
    final link = ReplayBandLink()..writeGate = gate;
    final inFlight = link.write(kOuraCommandChar, <int>[0x10]);
    // The write is past acceptance and parked at the gate — proof, not a
    // timer.
    await link.gateEntered;
    // close() WHILE the write is parked: the immediate refusal goes into
    // force under the in-flight write.
    await link.close();
    // Release the parked write: it proceeds past the gate and must meet
    // the refusal that came into force while it was parked.
    gate.complete();
    expect(await inFlight, isFalse,
        reason: 'a write that was in flight when the link closed must '
            'not report success afterwards');
    expect(link.writes, hasLength(1),
        reason: 'the write WAS accepted before close (like an operation '
            'already handed to the plugin queue) — the record stays, '
            'but the VERDICT is refusal');
  });

  test('the close contract separates immediate refusal from completed '
      'shutdown', () async {
    // (b) the refusal is in force IMMEDIATELY (synchronously at the top
    // of close), a separate thing from (c) the awaited, asynchronous
    // stream shutdown. `writesRefused` is the synchronous half, `closed`
    // plus a gone listener the completed half.
    final link = ReplayBandLink();
    final sub = link.notify(kOuraNotifyChar).listen((_) {});
    expect(link.writes, isEmpty);
    // BEFORE close: writes go through.
    expect(await link.write(kOuraNotifyChar, [0x01]), isTrue);
    expect(link.writes, hasLength(1));
    await link.close();
    // (b) immediate refusal, already in force at the top of close:
    expect(link.writesRefused, isTrue,
        reason: 'the write refusal must be synchronous, not "once the '
            'closes finish"');
    // (c) the asynchronous shutdown COMPLETED: channels closed, listener
    // gone.
    expect(link.closed, isTrue);
    expect(link.isListening(kOuraNotifyChar), isFalse);
    await sub.cancel();
    // (a) writes after close: refused, and NOT recorded.
    expect(await link.write(kOuraNotifyChar, [0x02]), isFalse,
        reason: 'the close contract: no writes after close');
    expect(link.writes, hasLength(1),
        reason: 'a refused write must not be recorded');
  });

  test('a stranded bookmark reports the session as NOT synced', () async {
    // A bookmark past the end of the ring is a recoverable fault (the next
    // sync re-reads from zero), but THIS session synced nothing: reporting it
    // as "Synced." would hide the fault behind a success message.
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '9391523');
    final ok = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 4096)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    expect(ok, isFalse);
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 0);
  });

  test('a sleep-stage row stamped in the future is refused', () async {
    await LocalDb.setCursor('oura_anchor:$_deviceId', '0,$_nowSec');
    await _run([
      [
        _event(kOuraEvtSleepPhaseInformation, 10, _hex('000055aaff')),
        _event(kOuraEvtSleepPhaseInformation, 10000000, _hex('000055aaff')),
        _summary(2, 0),
      ],
    ]);
    // Vendor scalars are banked off the commit chain; wait for them.
    final db = await LocalDb.instance;
    var rows = <Map<String, Object?>>[];
    for (var i = 0; i < 200 && rows.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      rows = await db.query('observation');
    }
    expect(rows, hasLength(4));
    expect(rows.every((r) => r['ts_ms'] == (_nowSec + 1) * 1000), isTrue,
        reason: 'the stage row a million seconds out is not written');
  });

  group('forgetRing', () {
    test('drops the device row', () async {
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kOura.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Ring',
      );
      expect(await OuraLink.pairedRingRow(), isNotNull);
      final ok = await OuraLink.forgetRing(_deviceId);
      expect(ok, isTrue);
      expect(await OuraLink.pairedRingRow(), isNull);
    });

    test('refuses the primary device id outright', () async {
      final ok = await OuraLink.forgetRing(LocalDb.kPrimaryDeviceId);
      expect(ok, isFalse);
    });

    test('a device id nothing paired is a harmless no-op', () async {
      final ok = await OuraLink.forgetRing('oura-never-paired');
      expect(ok, isTrue);
      expect(await OuraLink.pairedRingRow(), isNull);
    });
  });
}

String _hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
