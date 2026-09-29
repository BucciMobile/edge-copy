// The Oura ring as a [BandAdapter]: authenticate, drain its history by cursor,
// bank every byte, decode only what has been proven.
//
// NOTHING HERE HAS MET HARDWARE, and unlike `ble_hrs` there is not even a
// public specification to fall back on. It ships EXPERIMENTAL (ASSUMPTIONS R6),
// its rows carry a non-null `source` and `kDerivableSources` does not contain
// it, so nothing it writes can become a number until the owner has held a ring
// in his own hands. That is correct behaviour for an uncalibrated decoder, not
// a limitation to work around.
//
// WHY THIS IS THE OPPOSITE SHAPE TO gen4, and why the seam fits it. gen4's
// offload is TRIM-ON-ACK: the band deletes flash when the host says so, the
// handshake has three wire outcomes, and the decision to trim depends on
// whether the HOST's durable commit landed (ASSUMPTIONS G1-G4 — which is why
// gen4 is not behind this seam). Oura's is FETCH-BY-CURSOR: the ring never
// deletes anything on our say-so, there is no acknowledgement in the protocol
// at all, and the host's only state is a bookmark. Re-reading a range is
// idempotent — 48.5% of our own capture is the same records delivered
// twice, and `decoded_onehz` is keyed `(device_id, ts_ms)` with REPLACE, so a
// re-read overwrites rather than duplicates.
//
// That is exactly the "fetch-by-range: `confirm()` advances the adapter's own
// cursor" row in [OffloadCheckpoint]'s own table, and this file is the first
// implementation of it. The ordering still holds and still means something: the
// cursor does not move until the host has committed, so an interrupted sync
// re-reads rather than skips.
//
// PAIRING EVICTS THE OURA APP, AND IT IS A PRECONDITION RATHER THAN A SIDE
// EFFECT. The ring holds exactly one 16-byte key and will only accept a new one
// while it is FACTORY RESET — so a ring that is currently onboarded to Oura's
// app cannot be paired here at all until the owner factory-resets it, which is
// what removes it from that app. There is no state in which both work. Any
// pairing UI must say that before the user commits, not after.
//
// THE KEY IS OURS AND IT NEVER LEAVES THE PHONE. It is generated locally, there
// is no vendor server anywhere in the handshake and no Oura account is needed —
// which is the whole reason this band is not declined the way a vendor-issued
// pairing token would be. Losing it costs another factory reset, nothing more.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:pointycastle/export.dart' show AESEngine, ECBBlockCipher, KeyParameter;

import '../../data/observation.dart'
    show Observation, ObservationSource;
import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// Encrypt one authentication challenge.
///
/// The ring issues a 15-byte nonce; PKCS#7 pads it to exactly one 16-byte block
/// (a single 0x01), and the answer is that block under AES-128 in ECB mode with
/// the pairing key. One block, so ECB's usual objection — that identical
/// plaintext blocks repeat — has nothing to bite on, and the ring picks a fresh
/// nonce per connection.
///
/// Exposed rather than private so the test can pin it against a known vector
/// without a radio.
Uint8List ouraAuthResponse(List<int> key, List<int> nonce) {
  if (key.length != 16 || nonce.length != 15) {
    throw ArgumentError('Oura auth takes a 16-byte key and a 15-byte nonce');
  }
  final block = Uint8List(16)
    ..setRange(0, 15, nonce)
    ..[15] = 0x01;
  final out = Uint8List(16);
  ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(Uint8List.fromList(key)))
    ..processBlock(block, 0, out, 0);
  return out;
}

/// One Oura session.
///
/// NOT const and not a registry singleton, because it needs three things a
/// const adapter cannot hold: the pairing key, the cursor to resume from, and
/// the time origin to stamp against. All three belong to the HOST — the key is
/// a secret it stores, the other two are bookmarks it persists — and handing
/// them in at construction is what lets the seam stay a one-way
/// `Stream<BandEvent>` instead of growing an inbound command channel. Each one
/// comes back out as a [BandNote] when it moves, so the host never has to
/// re-derive a second copy of something this file already knows.
class OuraAdapter extends BandAdapter {
  /// The 16-byte pairing key this phone generated and wrote to this ring.
  final List<int> key;

  /// Where to resume the history drain, on the ring's decisecond clock. 0 asks
  /// for everything the ring still holds.
  final int startCursorDs;

  /// The `(ring decisecond, Unix second)` pair a previous session measured, if
  /// the host kept one.
  ///
  /// THIS IS WHAT MAKES A TIMESTAMP REPRODUCIBLE ACROSS CONNECTS. The ring
  /// stamps on a decisecond counter with no documented epoch and there is no
  /// command anywhere in the protocol that reads its clock back — a measured
  /// `time_sync` event is the ONLY bridge between the two, and it lands wherever
  /// the ring happened to record one. Handing the last known pair in means a
  /// given decisecond maps to the same second on every later session, so a
  /// re-read overwrites its own row instead of writing a second copy of the
  /// same physiological second under a key REPLACE can never collapse.
  final (int ds, int unix)? anchor;

  /// Wall-clock now, in Unix seconds. Injected so a fixture replay is
  /// deterministic — `DateTime.now()` does not appear in this file.
  final int Function() nowSeconds;

  /// How long to wait for a reply the ring owes us.
  final Duration replyTimeout;

  /// How long to wait for the host to commit a batch and call `confirm`.
  /// Expiring is SAFE: the cursor does not move, so the batch is re-read.
  /// Overridable only so a test does not have to sit through it.
  final Duration confirmTimeout;

  OuraAdapter({
    required this.key,
    this.startCursorDs = 0,
    this.anchor,
    int Function()? nowSeconds,
    this.replyTimeout = const Duration(seconds: 5),
    this.confirmTimeout = const Duration(seconds: 30),
  })  : nowSeconds = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000),
        _anchor = anchor;

  @override
  BandEntry get entry => kOura;

  /// NOTHING, and that is the honest answer today rather than a placeholder.
  ///
  /// The ring emits beat-to-beat intervals, SpO2 and a hypnogram, and this
  /// adapter decodes none of them: their layouts are bit-packed and there is
  /// not one captured byte of any of them to check a decoder against. A
  /// declared-but-absent signal is WORSE than a missing one (see
  /// [BandAdapter.signals]) — it turns a card that should delete itself into
  /// one that is permanently empty — so nothing is claimed until a decoder
  /// exists and a real capture has met it.
  ///
  /// Temperature is emitted below and still not declared here, deliberately:
  /// [InputSignal.skinTempRaw] means RELATIVE ADC COUNTS (I8), and this ring
  /// reports absolute degrees Celsius. They are not the same input and the
  /// per-family calibration that I8 exists to key does not apply. There is no
  /// member for absolute temperature and one should not be invented for a band
  /// nobody owns.
  ///
  /// Same ruling for the sleep-stage scalars `_emit` now emits: the decoder
  /// exists (protocol PR #71) but no capture from a ring THIS project held has
  /// met it, so [InputSignal.vendorScalars] stays undeclared too — the rows
  /// land in `observation` either way, and a declared-but-unverified signal is
  /// the permanently-empty card the header note above refuses.
  @override
  Map<InputSignal, Duration> get signals => const {};

  /// How many events one history request may return. The wire field is a u8,
  /// so this is its ceiling, and it is also what tells a full batch from a
  /// short one when the cursor is advanced.
  static const int _kMaxEventsPerBatch = 255;


  /// The (ring decisecond, Unix second) pair this session is stamping against.
  ///
  /// Seeded from [anchor] and thereafter only IMPROVED — by a `time_sync`
  /// event, the one record that carries both clocks. Never re-derived per
  /// batch: a re-anchored batch would write the same physiological second under
  /// a different `ts_ms` and duplicate rows that REPLACE cannot collapse.
  ///
  /// THERE IS NO FALLBACK, and that is the whole point. Seeding this from the
  /// ARRIVAL of the first batch — the obvious-looking guess — produces an origin
  /// that moves by the BLE delivery jitter on every connect, which is exactly
  /// the duplication above with a plausible-looking number on it. When there is
  /// no anchor there is no timestamp, and a sample without one is not emitted.
  (int ds, int unix)? _anchor;

  /// Readings decoded before an origin existed, as `(ds, °C)`.
  ///
  /// Every connect sets the ring's clock, so the ring records a fresh
  /// `time_sync` — but it records it at its CURRENT decisecond, which is the
  /// END of the drain. On a first pairing that is after the whole of its
  /// history, so abstaining on the spot would throw all of it away. Held
  /// instead, and stamped by the batch that finally carries an origin. If none
  /// ever does, they are dropped: the frames are still handed over verbatim in
  /// every [SampleBatch], so nothing is lost that was not already banked.
  final List<(int ds, double tempC)> _held = [];

  /// Hypnogram aggregates decoded before an origin could stamp them, as
  /// `(ds, stage, minutes)`.
  ///
  /// Same lifecycle as [_held], and it exists for the same reason: the ring
  /// stamps events on its own decisecond counter, and an observation row is
  /// keyed `(device_id, ts_ms, source_kind, COALESCE(vendor_key, key))` — an
  /// aggregate stamped on a WRONG second does not just miss a night, it
  /// REPLACEs whatever row the right second would have produced and puts a
  /// made-up number in its place. So the per-stage minute totals are held
  /// until an origin can convert `ds` to a Unix second, and dropped at the
  /// end of the drain when none ever could — the frames are still handed
  /// over verbatim in every [SampleBatch], so nothing is lost that was not
  /// already banked, and a later session with a stored anchor re-reads them.
  final List<(int ds, OuraSleepPhase stage, double minutes)> _heldSleepStages = [];

  /// The Unix second [ds] falls on, or null when no origin is known.
  int? _anchorUnixFor(int ds) {
    final a = _anchor;
    if (a == null) return null;
    // 10 deciseconds to the second. The subtraction is on the ring's own clock,
    // so the SPACING between records is exact however wrong the origin is.
    return a.$2 + (ds - a.$1) ~/ 10;
  }

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final inbox = _Inbox();
    final sub = link.notify(kOuraNotifyChar).listen(
          (rec) {
            final f = parseOuraFrame(rec.$2);
            // The notification bytes AS DELIVERED, not `f` re-encoded: the ring
            // is known to append trailing bytes past `parseFrame`'s declared
            // length (see its doc), and those bytes are exactly what a future
            // decoder for the still-undecoded event types needs. Kept even
            // though `f` was accepted, because it is `raw_archive`'s copy, not
            // the parser's.
            if (f != null) {
              inbox.add(rec.$1, f, Uint8List.fromList(rec.$2));
            }
          },
          onDone: inbox.close,
          onError: (Object _) => inbox.close(),
        );
    try {
      if (!await _authenticate(link, inbox)) return;

      // Both writes are documented preconditions of a history drain rather than
      // housekeeping. The clock set is also what makes a later `time_sync`
      // event exist at all, and that event is the only anchor between the
      // ring's decisecond counter and a date. A silent write failure here does
      // not fail loud on its own: a refused notify-flag write leaves every
      // later batch waiting out a full `replyTimeout` for frames that will
      // never arrive, and a refused time-sync write leaves the session with no
      // measured origin — there is no arrival-time fallback here (that is
      // `TimeAnchor.arrival` on the *held* reading once SOME anchor exists,
      // never a substitute for having none), so every reading this session
      // sees is held in `_held` and stamped only if a stored anchor from an
      // earlier session covers it.
      if (!await link.write(kOuraCommandChar, ouraCmdSetNotifyFlags(0x3f))) {
        link.log('oura: notify-flag write refused; ending the drain.');
        return;
      }
      if (!await link.write(kOuraCommandChar, ouraCmdSyncTime(nowSeconds()))) {
        link.log('oura: time-sync write refused; no new origin this session. '
            'Readings are stamped only if a stored anchor covers them.');
      }

      var cursor = startCursorDs;
      // A misbehaving ring that answers every request with the same batch would
      // otherwise spin here forever on a live radio.
      for (var batch = 0; batch < 5000; batch++) {
        // Passed explicitly rather than left to the builder's default: the
        // cursor advance below compares the batch's own count against this
        // number, and two copies of it that could drift is a silent skip.
        final req = ouraCmdGetEvents(cursor, maxEvents: _kMaxEventsPerBatch);
        if (!await link.write(kOuraCommandChar, req)) {
          link.log('oura: history request refused; ending the drain.');
          return;
        }
        final got = await _collectBatch(inbox);
        if (got == null) {
          // THE SUMMARY IS THE ONLY BATCH TERMINATOR THIS PROTOCOL HAS. A batch
          // that ends without one is a link that died mid-batch (or a radio
          // that never sent it), and treating that as "drained" is the one
          // wrong answer this loop could give: the frames it did deliver were
          // collected into a `_Batch` that never reaches a `SampleBatch`, so
          // they are not banked this session — and the CURSOR must not move
          // on the strength of a batch whose end was never announced, because
          // the ring may have held more behind the summary that never arrived.
          // Ending the session leaves the bookmark put, so the next sync
          // re-reads from the last confirmed boundary. Nothing is lost either
          // way — the ring never deletes on our say-so.
          link.log('oura: no batch summary within the reply window.');
          return;
        }
        if (got.events.isEmpty) {
          // A CURSOR THE RING CANNOT ANSWER, told apart from an empty ring.
          //
          // The decisecond counter is an UPTIME, so a ring that reboots
          // restarts it near zero — and a bookmark from before the reboot is
          // then far AHEAD of everything it holds. Every request from there
          // matches nothing, forever, and the sync looks exactly like "no new
          // data" while the ring quietly fills up. `bytesLeft` is what
          // separates them: data remaining and none delivered is not an empty
          // ring, it is a bookmark pointing past the end. The host's remedy is
          // to drop the bookmark and re-read from zero, which is free — a
          // re-read of this band is idempotent by design.
          if (got.summary.bytesLeft > 0) {
            link.log('oura: the ring reports ${got.summary.bytesLeft} bytes '
                'left but answered this cursor with nothing.');
            yield const BandNote('oura_cursor_stranded');
          }
          return;
        }

        // A REPLAYED TAIL IS DROPPED BEFORE ANYTHING ELSE SEES IT. The ring's
        // documented answer to a cursor past its newest event is not an empty
        // batch but the LAST FEW EVENTS AGAIN (observed live on a Horizon and
        // re-confirmed against Ring 4/5 notes by the open_oura project,
        // 2026-09-24): it is a replay, not new data, and a session that treats
        // it as either new (advancing the cursor to the replay's own stamp —
        // which cannot exceed the bookmark it was asked from, so the loop asks
        // the same question forever) or as an ordinary short batch (banking
        // duplicates — harmless to the tables, idempotent by REPLACE/PK, but it
        // turns every idle sync into a busy loop that never ends) is wrong.
        // Both halves below stop that: events older than the cursor the request
        // asked from are discarded here, and the batch they leave behind counts
        // as empty — which is the one honest answer, because a cursor the ring
        // answered with only replays is exactly a cursor with nothing new after
        // it. This is the fetch-by-currency sibling of the stranded-bookmark
        // check below, and the two must not be merged: a stranded bookmark is a
        // bookmark the ring CANNOT answer (rebooted counter), a replayed tail
        // is one it answers with what it still holds — only the former resets
        // the bookmark, because only the former makes every future record
        // unreachable behind it.
        final fresh = <OuraEvent>[
          for (final e in got.events)
            if (e.tsDs >= cursor) e,
        ];
        if (fresh.length != got.events.length) {
          // The RAW copies go with the events they belong to — `_collectBatch`
          // fills the two lists in lockstep (one raw entry per accepted event,
          // in arrival order), so the replay's own bytes are dropped by the same
          // cut. `raw_archive` would dedupe them anyway (PRIMARY KEY on hex),
          // but a batch must not hand a later decoder re-delivered frames mixed
          // into new data it is being asked to trust.
          final keepRaw = <Uint8List>[
            for (var i = 0; i < got.events.length; i++)
              if (got.events[i].tsDs >= cursor) got.raw[i],
          ];
          got.raw.clear();
          got.raw.addAll(keepRaw);
        }
        if (fresh.isEmpty && got.events.isNotEmpty) {
          link.log('oura: the ring replayed ${got.events.length} event(s) '
              'below the cursor; nothing new after $cursor.');
          // A REPLAY WITH BYTES REMAINING IS A STRANDED BOOKMARK TOO. The
          // rebooted-counter scenario lands here exactly the way it lands in
          // the empty-batch branch above — everything the ring now holds is
          // below a bookmark taken before the reboot — except this ring answers
          // with its last few pre-reboot events instead of nothing. Same
          // signal, same remedy: the bookmark is unanswerable and must be
          // dropped, or the ring quietly fills up behind it forever.
          //
          // AND THE BOOT RECORD ALONE IS NOT EVIDENCE OF A NEW REBOOT. A boot
          // record stamped below the cursor is by definition one a previous
          // session already read and advanced past — a normal sync's replayed
          // tail can carry it indefinitely, and treating it as a fresh reboot
          // would reset a VALID bookmark on every idle sync and re-read
          // history forever. The failure this guard exists for — a hardware
          // factory reset leaving the counter restarted below a stale
          // bookmark — is not distinguishable from the plain stranded case
          // by the boot record's presence, only by the ring still holding
          // something it could not deliver, which is the same `bytesLeft > 0`
          // signal the empty-batch branch above runs on. So the reset runs on
          // that signal alone, and the boot record stays what it is: an
          // archived frame for a future decoder, not a reboot tripwire.
          if (got.summary.bytesLeft > 0) {
            yield const BandNote('oura_cursor_stranded');
          }
          return;
        }
        got.events.clear();
        got.events.addAll(fresh);

        for (final e in got.events) {
          final unix = decodeTimeSync(e);
          if (unix == null) continue;
          // A better origin for this record and every one after it, and for
          // everything still held. Applied BEFORE the batch is stamped so the
          // batch carrying the sync is itself correct.
          _anchor = (e.tsDs, unix);
          // Surfaced so the host can persist it without re-deriving one of its
          // own. Two implementations of an origin is two origins.
          yield BandNote('oura_anchor', '${e.tsDs},$unix');
        }

        yield* _emit(link, got);

        // THE ORDERING IS THE POINT. The host commits durably, then calls
        // confirm, and only then does the cursor move. Nothing is deleted
        // either way — the ring has no trim — so a host that never confirms
        // costs a re-read, never a record.
        final done = Completer<bool>();
        yield OffloadCheckpoint(
          () async {
            if (!done.isCompleted) done.complete(true);
            return true;
          },
          remaining: got.summary.bytesLeft,
        );
        final confirmed = await done.future
            .timeout(confirmTimeout, onTimeout: () => false);
        if (!confirmed) {
          link.log('oura: batch was not confirmed; leaving the cursor put.');
          return;
        }
        // A FULL BATCH RE-READS ITS LAST DECISECOND; A SHORT ONE MOVES PAST IT.
        //
        // The cursor is a TIMESTAMP, not a record index, and the batch cap is a
        // record count — so a batch that came back full may have been cut in
        // the middle of a decisecond that holds more records than fitted.
        // Jumping to `maxDs + 1` there silently drops the remainder, and
        // nothing downstream can tell: the gap is in the ring's flash, not in
        // ours. Re-reading `maxDs` instead costs one duplicated decisecond,
        // which `decoded_onehz`'s REPLACE key absorbs for free.
        //
        // The `> cursor` guard is the escape: a ring with a whole batch inside
        // one decisecond would otherwise re-ask for the same thing forever, and
        // a bounded loss beats an unbounded stall.
        final full = got.summary.received >= _kMaxEventsPerBatch;
        cursor = (full && got.maxDs > cursor) ? got.maxDs : got.maxDs + 1;
        yield BandNote('oura_cursor_ds', cursor);
        if (got.summary.bytesLeft <= 0) return;
      }
    } finally {
      await sub.cancel();
    }
  }

  /// Nonce, encrypt, answer. False on any refusal — a session that carries on
  /// unauthenticated gets `auth required` to every command and looks identical
  /// to a dead link.
  Future<bool> _authenticate(BandLink link, _Inbox inbox) async {
    if (!await link.write(kOuraCommandChar, ouraCmdAuthNonce())) return false;
    final challenge =
        await inbox.firstWhere((f) => ouraAuthNonce(f) != null, replyTimeout);
    if (challenge == null) {
      link.log('oura: no authentication challenge.');
      return false;
    }
    final answer = ouraAuthResponse(key, ouraAuthNonce(challenge)!);
    if (!await link.write(kOuraCommandChar, ouraCmdAuthenticate(answer))) {
      return false;
    }
    final reply =
        await inbox.firstWhere((f) => ouraAuthResult(f) != null, replyTimeout);
    final result = reply == null ? null : ouraAuthResult(reply);
    if (result != 0) {
      // Worth naming, because the remedies differ: a wrong key needs re-pairing
      // and a ring in factory reset needs its key installed first.
      link.log('oura: authentication refused (result ${result ?? "none"}).');
      return false;
    }
    return true;
  }

  /// Read frames until the batch summary arrives.
  Future<_Batch?> _collectBatch(_Inbox inbox) async {
    final events = <OuraEvent>[];
    final raw = <Uint8List>[];
    var maxDs = 0;
    // A misbehaving ring that keeps streaming non-summary frames would
    // otherwise spin here forever — each frame resets `replyTimeout`'s
    // window, so the timeout alone never bounds this loop. Same shape as the
    // outer `batch < 5000` guard in `run`.
    for (var frame = 0; frame < 5000; frame++) {
      final rec = await inbox.next(replyTimeout);
      if (rec == null) return null;
      final (_, f, rawBytes) = rec;
      final summary = parseBatchSummary(f);
      if (summary != null) return _Batch(events, raw, maxDs, summary);
      if (ouraIsAuthRequired(f)) return null;
      final e = parseOuraEvent(f);
      if (e == null) continue;
      events.add(e);
      // The bytes AS THE RADIO DELIVERED THEM, not `[f.tag, f.payload.length,
      // ...f.payload]` reconstructed from the parsed frame: `parseOuraFrame`
      // truncates to the declared length and the ring is known to append
      // bytes past it (see its doc). Re-encoding here would bank this file's
      // idea of the frame instead of what a future decoder for the
      // still-undecoded event types actually needs, and the trailing bytes are
      // unrecoverable once dropped — `raw_archive` is never pruned but it
      // cannot un-truncate what was never written.
      raw.add(rawBytes);
      if (e.tsDs > maxDs) maxDs = e.tsDs;
    }
    return null;
  }

  /// Turn one collected batch into events for the host.
  Stream<BandEvent> _emit(BandLink link, _Batch got) async* {
    final samples = <NeutralSample>[];
    for (final e in got.events) {
      switch (e.tag) {
        case kOuraEvtTemp:
        case kOuraEvtTempPeriod:
          final t = decodeTemperatures(e);
          // The array's probes are not identified — one may be an ambient
          // reference — so the first is taken and the rest are left in the
          // archive rather than averaged into a number that means nothing.
          if (t != null && t.isNotEmpty) _held.add((e.tsDs, t.first));
        case kOuraEvtDebugData:
          final d = decodeDebugData(e.body);
          if (d == null) break;
          if (d.text != null) link.log('oura fw: ${d.text}');
          if (d.batteryPct != null) yield BandNote('battery', d.batteryPct);
          if (d.batteryMv != null) yield BandNote('battery_mv', d.batteryMv);
        case kOuraEvtSleepPhaseInformation:
        case kOuraEvtSleepPhaseDetails:
        case kOuraEvtSleepPhaseData:
          // THE RING'S OWN SLEEP STAGING, banked as vendor scalars. This is
          // the one event family whose payload is a CONCLUSION the hardware
          // computed itself, not a signal to derive from — the native
          // `SleepPhase_OSSAv1` classification, 30 s epochs, decoded by
          // `decodeSleepPhases` in `openstrap_protocol` (PR #71, ported code
          // for code from the open_oura project's Rust decoder, whose
          // hardware provenance is a Gen 3 Horizon capture — R6: nothing here
          // has met OUR ring).
          //
          // WHAT IS KEPT IS THE EVENT'S OWN DELIMITATION, not a night's. The
          // wire hands over one hypnogram per event, and where a night's
          // boundary sits is a judgement this file has no evidence for —
          // `sleep_summary_1` (0x49) carries start/end as MINUTE OFFSETS that
          // open_oura itself marks unvalidated, so rolling events up to a
          // night would be inventing the one boundary that decides which
          // minutes count. One event's stage totals are exactly what the ring
          // claims, no more.
          //
          // THE PER-STAGE MINUTE COUNTS ARE THE SCALARS. The full epoch
          // series is deliberately NOT written anywhere: `observation` is
          // scalars only ("a vendor hypnogram ... has no consumer — give it
          // a table of its own when something is actually going to read it",
          // db.dart), the frames stay in `raw_archive` for the day a consumer
          // exists, and durations are honest scalars — they are measurements
          // of the ring's own classification, not scores out of 100.
          //
          // `vendorKey`, not `key`: deep/light/REM/awake minutes are THEIR
          // stages under THEIR staging algorithm, a proprietary composite in
          // exactly the sense `Observation`'s split exists to fence — the
          // same `key` under two algorithms is the ambiguity the split
          // stops, and our own `stages4` staging is a different algorithm
          // answering the same question.
          final hyp = decodeSleepPhases(e);
          if (hyp == null) break;
          final minutesPerStage = <OuraSleepPhase, int>{};
          for (final phase in hyp.phases) {
            if (phase == null) continue;
            minutesPerStage.update(phase, (m) => m + 1, () => 1);
          }
          final at = _anchorUnixFor(e.tsDs);
          if (at == null) {
            for (final entry in minutesPerStage.entries) {
              _heldSleepStages.add((e.tsDs, entry.key, entry.value * 0.5));
            }
            break;
          }
          final rows = [
            for (final entry in minutesPerStage.entries)
              Observation(
                at: DateTime.fromMillisecondsSinceEpoch(at * 1000),
                sourceKind: ObservationSource.vendor,
                vendorKey: 'sleep_${entry.key.name}_min',
                value: entry.value * 0.5,
                unit: 'min',
                attribution: 'Oura',
              ),
          ];
          yield VendorScalars(rows);
      }
    }
    // Stamp everything an origin can now reach — this batch's readings and any
    // held from earlier ones. What still cannot be stamped stays held for a
    // later batch, and is dropped at the end of the drain rather than guessed
    // at: a plausible wrong second is worse than a missing one, because nothing
    // downstream can tell it apart from a measurement.
    _held.removeWhere((h) {
      final unix = _anchorUnixFor(h.$1);
      if (unix == null) return false;
      samples.add(NeutralSample(
        anchor: TimeAnchor.arrival,
        tsEpoch: unix,
        skinTempC: h.$2,
      ));
      return true;
    });
    final stageRows = <Observation>[];
    _heldSleepStages.removeWhere((h) {
      final unix = _anchorUnixFor(h.$1);
      if (unix == null) return false;
      stageRows.add(Observation(
        at: DateTime.fromMillisecondsSinceEpoch(unix * 1000),
        sourceKind: ObservationSource.vendor,
        vendorKey: 'sleep_${h.$2.name}_min',
        value: h.$3,
        unit: 'min',
        attribution: 'Oura',
      ));
      return true;
    });
    if (stageRows.isNotEmpty) yield VendorScalars(stageRows);
    // EVERY event frame is archived, including the ones just decoded and every
    // one that was not. Beat intervals, SpO2 and steps all live in here
    // undecoded, and that is the point: the bytes are banked now so a decoder
    // written when someone owns a ring can be run over them, instead of a
    // guess being run over them today (owner rulings R1-R3). The hypnogram is
    // decoded now, and its bytes are banked TOO - the scalars above are the
    // aggregates, and the epoch series itself stays here for the day a
    // consumer for it exists (`observation` is scalars only, db.dart).
    yield SampleBatch(samples, raw: got.raw);
  }
}

/// One batch of history, as collected off the wire.
class _Batch {
  final List<OuraEvent> events;
  final List<Uint8List> raw;
  final int maxDs;
  final OuraBatchSummary summary;
  const _Batch(this.events, this.raw, this.maxDs, this.summary);
}

/// Frames off the notify characteristic, buffered so that a reply landing
/// before anyone is waiting is not dropped.
///
/// Hand-rolled rather than `package:async`'s `StreamQueue` because that would
/// mean promoting a transitive dependency to a direct one for one class, and
/// the whole of what this session needs is "the next frame, or nothing".
class _Inbox {
  // Third element is the notification bytes AS DELIVERED — `raw_archive`'s
  // copy, kept alongside the parsed frame rather than re-derived from it. See
  // `_collectBatch` for why re-deriving loses bytes.
  final List<(int, OuraFrame, Uint8List)> _buf = [];
  Completer<(int, OuraFrame, Uint8List)?>? _waiter;
  bool _closed = false;

  void add(int atSec, OuraFrame f, Uint8List raw) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete((atSec, f, raw));
      return;
    }
    _buf.add((atSec, f, raw));
  }

  void close() {
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }

  /// The next frame, or null on timeout or a closed link.
  Future<(int, OuraFrame, Uint8List)?> next(Duration timeout) {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    if (_closed) return Future.value(null);
    final w = Completer<(int, OuraFrame, Uint8List)?>();
    _waiter = w;
    return w.future.timeout(timeout, onTimeout: () {
      if (identical(_waiter, w)) _waiter = null;
      return null;
    });
  }

  /// The next frame satisfying [test], discarding what comes before it.
  /// [timeout] bounds the whole search, not each frame.
  Future<OuraFrame?> firstWhere(
    bool Function(OuraFrame) test,
    Duration timeout,
  ) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < timeout) {
      final rec = await next(timeout - deadline.elapsed);
      if (rec == null) return null;
      if (test(rec.$2)) return rec.$2;
    }
    return null;
  }
}
