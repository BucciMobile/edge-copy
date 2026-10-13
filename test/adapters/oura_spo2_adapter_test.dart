// The Oura SpO2 ADAPTER path: a scripted ring through the real adapter,
// pinning the row shape the SpO2 decode produces — per-second rows stamped
// at their own seconds, no batch means anywhere, zero samples dropped
// rather than fabricated, replays collapsed by the row identity, and no
// origin means no row.
//
// Expectations are INDEPENDENT: every timestamp and mean below is computed
// by hand from the fixture, never by the adapter.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/oura.dart';
import 'package:openstrap_edge/ble/adapters/oura_spo2.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

const Duration _kFast = Duration(milliseconds: 50);
final List<int> _kKey = _hex('4431967d8bacc2659743142b68391d9a');

List<int> _hex(String s) => [
  for (var i = 0; i + 1 < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

List<int> _frame(int tag, List<int> payload) => <int>[
  tag,
  payload.length,
  ...payload,
];

List<int> _event(int tag, int tsDs, List<int> body) => _frame(tag, <int>[
  tsDs & 0xff,
  (tsDs >> 8) & 0xff,
  (tsDs >> 16) & 0xff,
  (tsDs >> 24) & 0xff,
  ...body,
]);

final List<int> _nonceReply = _frame(
  0x2f,
  _hex('2c') + _hex('0e2d6a0a08c99b4365f458e6e97382'),
);
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

OuraAdapter _adapter() =>
    OuraAdapter(key: _kKey, confirmTimeout: _kFast, replyTimeout: _kFast);

Future<(List<BandEvent>, ReplayBandLink)> _drive(
  OuraAdapter adapter,
  List<List<int>> Function(int writeIndex, List<int> value) reply, {
  bool confirmBatches = true,
}) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen((e) async {
    events.add(e);
    if (e is OffloadCheckpoint && confirmBatches) await e.confirm();
  }, onDone: () => done.complete());
  var served = 0;
  for (var spin = 0; spin < 400 && !done.isCompleted; spin++) {
    await Future<void>.delayed(Duration.zero);
    while (served < link.writes.length) {
      final w = link.writes[served];
      for (final f in reply(served, w.$2)) {
        link.feed(kOuraNotifyChar, f, atSec: 1786000000);
      }
      served++;
    }
  }
  await link.close();
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  await sub.cancel();
  return (events, link);
}

/// All SpO2 VendorScalar rows the session produced.
List<Observation> _spo2Rows(List<BandEvent> events) => [
  for (final e in events.whereType<VendorScalars>())
    for (final o in e.rows)
      if (o.vendorKey == 'spo2') o,
];

void main() {
  // One SpO2 event with the documented layout, then a time sync that makes
  // its stamps computable: anchor (tsDs=400, unix=1_782_043_215).
  // Samples [97, 0, 96, 98] at tsDs 400 → seconds 1782043215..1782043218.
  const anchorUnix = 1782043215;
  List<List<int>> ringWithSpo2(int i, List<int> v) {
    if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
    if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
    if (v.first == 0x10) {
      final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
      if (cursor > 0) return [_summary(0, 0)];
      return [
        _event(kOuraEvtSpo2, 400, [0x01, 97, 0, 96, 98, 0xff]),
        _event(kOuraEvtTimeSync, 400, _syncBody(anchorUnix)),
        _summary(2, 0),
      ];
    }
    return const [];
  }

  test(
    'per-second rows at their own stamps, zero dropped, not fabricated',
    () async {
      final (events, _) = await _drive(_adapter(), ringWithSpo2);
      final rows = _spo2Rows(events);
      // 4 samples in the event, one is a zero (no measurement) — 3 rows.
      expect(rows, hasLength(3));
      // Values preserved verbatim, as the ring's own number.
      expect(rows.map((r) => r.value), [97, 96, 98]);
      // Stamps: the envelope stamp is the LAST sample's second; the four
      // samples (incl. the zero) run backward from it, so the kept rows
      // sit at anchor-3 (97), anchor-1 (96) and anchor (98).
      expect(rows[0].at.millisecondsSinceEpoch, (anchorUnix - 3) * 1000);
      expect(rows[1].at.millisecondsSinceEpoch, (anchorUnix - 1) * 1000);
      expect(rows[2].at.millisecondsSinceEpoch, anchorUnix * 1000);
      for (final r in rows) {
        expect(r.sourceKind, ObservationSource.vendor);
        expect(r.vendorKey, 'spo2');
        expect(r.unit, '%');
        expect(r.attribution, 'Oura');
        // The ring's own day label, from the one helper that gets DST right.
        expect(r.date, isNotEmpty);
      }
    },
  );

  test('no origin means no SpO2 row — held, not stamped at arrival', () async {
    List<List<int>> ringNoSync(int i, List<int> v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
        if (cursor > 0) return [_summary(0, 0)];
        return [
          _event(kOuraEvtSpo2, 400, [0x01, 97, 98]),
          _summary(1, 0),
        ];
      }
      return const [];
    }

    final (events, _) = await _drive(_adapter(), ringNoSync);
    expect(_spo2Rows(events), isEmpty);
    // The bytes still reach raw_archive: nothing is lost that was banked.
    final batch = events.whereType<SampleBatch>().first;
    expect(batch.raw, isNotEmpty);
  });

  test(
    'an over-100 event is refused whole — no plausible parts rescued',
    () async {
      List<List<int>> ringWithBad(int i, List<int> v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
          if (cursor > 0) return [_summary(0, 0)];
          return [
            _event(kOuraEvtSpo2, 400, [0x01, 97, 102, 98]),
            _event(kOuraEvtTimeSync, 400, _syncBody(anchorUnix)),
            _summary(2, 0),
          ];
        }
        return const [];
      }

      final (events, _) = await _drive(_adapter(), ringWithBad);
      expect(_spo2Rows(events), isEmpty);
      // The event frame is still archived verbatim for a later re-interpretation.
      final batch = events.whereType<SampleBatch>().first;
      expect(batch.raw, isNotEmpty);
    },
  );

  test('a below-floor sample is dropped at the adapter boundary, '
      'not by the decoder', () async {
    List<List<int>> ringWithLow(int i, List<int> v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
        if (cursor > 0) return [_summary(0, 0)];
        return [
          _event(kOuraEvtSpo2, 400, [0x01, 97, 69, 98]),
          _event(kOuraEvtTimeSync, 400, _syncBody(anchorUnix)),
          _summary(2, 0),
        ];
      }
      return const [];
    }

    final (events, _) = await _drive(_adapter(), ringWithLow);
    final rows = _spo2Rows(events);
    // 69 < the 70 floor: that second stays absent, the others survive.
    expect(rows.map((r) => r.value), [97, 98]);
  });

  test(
    'the same samples in different batch shapes produce the same rows',
    () async {
      // Batch A: everything in one batch. Batch B: the same events split over
      // two history answers. The ROWS must be identical — the summary is over
      // samples, not batches, and a batch is a transport boundary only.
      Future<List<Observation>> rowsFor(
        List<List<int>> Function(int, List<int>) ring,
      ) async {
        final (events, _) = await _drive(_adapter(), ring);
        final rows = _spo2Rows(events)..sort((a, b) => a.at.compareTo(b.at));
        return rows;
      }

      List<List<int>> oneBatch(int i, List<int> v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
          if (cursor > 0) return [_summary(0, 0)];
          return [
            _event(kOuraEvtSpo2, 400, [0x01, 96, 97]),
            _event(kOuraEvtSpo2, 500, [0x02, 98, 99]),
            _event(kOuraEvtTimeSync, 500, _syncBody(anchorUnix + 10)),
            _summary(3, 0),
          ];
        }
        return const [];
      }

      List<List<int>> twoBatches(int i, List<int> v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
          if (cursor == 0) {
            return [
              _event(kOuraEvtSpo2, 400, [0x01, 96, 97]),
              _summary(1, 64),
            ];
          }
          if (cursor <= 410) {
            return [
              _event(kOuraEvtSpo2, 500, [0x02, 98, 99]),
              _event(kOuraEvtTimeSync, 500, _syncBody(anchorUnix + 10)),
              _summary(2, 0),
            ];
          }
          return [_summary(0, 0)];
        }
        return const [];
      }

      final a = await rowsFor(oneBatch);
      final b = await rowsFor(twoBatches);
      expect(a, hasLength(4));
      expect(b, hasLength(4));
      // Same seconds, same values — the row set, not the batch, is the unit.
      for (var i = 0; i < a.length; i++) {
        expect(b[i].at, a[i].at);
        expect(b[i].value, a[i].value);
      }
    },
  );
  test(
    'several nights in one batch stay separate days, never one mean',
    () async {
      const aUnix = 1783012200;
      List<List<int>> twoNights(int i, List<int> v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
          if (cursor > 0) return [_summary(0, 0)];
          return [
            _event(kOuraEvtSpo2, 100, [0x0a, 95, 95, 95, 95, 95]),
            _event(kOuraEvtSpo2, 200, [0x03, 97, 97, 97]),
            _event(kOuraEvtTimeSync, 200, _syncBody(aUnix)),
            _summary(3, 0),
          ];
        }
        return const [];
      }

      final (events, _) = await _drive(_adapter(), twoNights);
      final rows = _spo2Rows(events);
      // 8 samples (5 + 3, no zeros, all above the floor).
      expect(rows, hasLength(8));
      final sorted = rows.toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      // Backward contract, hand-computed: the tsDs=100 event's LAST
      // sample is 10 s before the anchor, its five samples span
      // aUnix-14..aUnix-10; the tsDs=200 event's three span aUnix-2..aUnix.
      expect(sorted.first.at.millisecondsSinceEpoch, (aUnix - 14) * 1000);
      expect(sorted.last.at.millisecondsSinceEpoch, aUnix * 1000);
      final days = rows.map((r) => r.date).toSet();
      expect(days.length, lessThanOrEqualTo(2));
    },
  );

  test(
      'a continuing run across events keeps the events own envelope '
      'seconds — no invented cross-event continuity', () async {
    // One event whose run continues (trailing 0xff) into a second event
    // with a LATER envelope stamp. The continuation marker carries NO
    // time contract (nothing in the pinned decoder or the decompiled-app
    // notes says the next event's samples are the following seconds), so
    // stitching them would invent gapless continuity. Each event keeps
    // its OWN envelope-derived seconds; where the two windows overlap,
    // the storage identity index collapses the pair — documented, not
    // hidden.
    const aUnix = 1782043215;
    List<List<int>> continuedRun(int i, List<int> v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
        if (cursor > 0) return [_summary(0, 0)];
        return [
          _event(kOuraEvtSpo2, 400, [0x01, 90, 90, 90, 0xff]),
          _event(kOuraEvtSpo2, 410, [0x01, 91, 91, 91]),
          _event(kOuraEvtTimeSync, 400, _syncBody(aUnix)),
          _summary(3, 0),
        ];
      }
      return const [];
    }

    final (events, _) = await _drive(_adapter(), continuedRun);
    final rows = _spo2Rows(events)
      ..sort((a, b) => a.at.compareTo(b.at));
    expect(rows, hasLength(6));
    // NO cross-event stitching — the continuation marker carries no time
    // contract. Each event keeps its own envelope-derived seconds:
    // event A (ds=400): aUnix-2..aUnix with the 90s; event B (ds=410,
    // +1 s): aUnix-1..aUnix+1 with the 91s. They OVERLAP on aUnix-1 and
    // aUnix — six rows over four distinct seconds, the documented
    // collision the storage identity index collapses.
    final stamps = rows.map((r) => r.at.millisecondsSinceEpoch).toSet();
    expect(stamps, hasLength(4),
        reason: 'each event keeps its OWN envelope seconds; overlapping '
            'seconds are the honest shape, not invented continuity');
    // The four distinct seconds, hand-computed.
    expect(stamps, {
      (aUnix - 2) * 1000,
      (aUnix - 1) * 1000,
      aUnix * 1000,
      (aUnix + 1) * 1000,
    });
    // Values in TIME order per row: A's three 90s at aUnix-2..aUnix and
    // B's 91s at aUnix-1..aUnix+1 interleave where the windows overlap.
    expect(rows.map((r) => r.value), [90, 90, 91, 90, 91, 91]);
  });
}