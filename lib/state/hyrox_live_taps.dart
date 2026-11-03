// hyrox_live_taps.dart — turns LIVE band double-taps into HYROX round
// boundaries while the phone is connected.
//
// The offline reconciler (hyrox_reconciler.dart) applies the same burst rule
// AFTER a drain; this handler applies it DURING the race, so the UI can show
// the current round immediately. Both paths converge on the same rule:
// a boundary is the FIRST tap of a cluster of >= [kMinTaps] double-taps where
// every tap is within [kTapWindowSec] of the cluster's first tap AND follows
// the previous tap without a longer pause (a chained 0/6/12 s sequence does
// NOT count). Per-station minimum-duration floors reject a tap during a
// station struggle. Boundaries are stamped 'gesture'; the reconciler later
// ignores taps at or before the last recorded boundary, so the two paths are
// idempotent together.
//
// Wired ONLY into the foreground/live event path (AppState._onLiveEvent),
// never the headless drain — a drained historical tap must not fire a live
// transition (same guard philosophy as GestureDispatcher's recency window;
// the band ts of a live tap is seconds old by construction).

import 'package:sqflite/sqflite.dart';

import '../data/hyrox_store.dart';
import 'hyrox_reconciler.dart'
    show kMinTaps, kTapWindowSec, kMinSegmentSec;

/// Double-tap event id, the only gesture the firmware emits today.
const int kHyroxLiveDoubleTapEventId = 14;

/// Pure, testable: incremental burst detection over a live tap stream.
class LiveBurstDetector {
  final List<int> _cluster = [];

  /// Feed one live tap (band timestamp, seconds). Returns the accepted
  /// boundary time — the FIRST tap of the burst — or null while the cluster
  /// has not cleared the gate yet.
  int? addTap(int ts) {
    if (_cluster.isNotEmpty) {
      final first = _cluster.first;
      final last = _cluster.last;
      // Anchored on the first tap AND no long pause inside the burst: a
      // chained 0 s / 6 s / 12 s sequence starts a new cluster at 12 s.
      if (ts > first + kTapWindowSec || ts - last > kTapWindowSec) {
        _cluster.clear();
      }
    }
    _cluster.add(ts);
    if (_cluster.length >= kMinTaps) {
      final at = _cluster.first;
      _cluster.clear();
      return at;
    }
    return null;
  }
}

/// Applies accepted live bursts to the ONE active HYROX session.
///
/// [db] is a getter because the database handle is async; the handler is
/// created before the DB is open. Every accepted burst re-reads the session
/// from the DB, so a relaunch or a reconciler-applied boundary is picked up.
class HyroxLiveTapHandler {
  HyroxLiveTapHandler(this._db, {this.log});

  final Future<Database> Function() _db;
  final void Function(String line)? log;

  final LiveBurstDetector _detector = LiveBurstDetector();

  /// Feed every live band event here. Cheap for non-tap events.
  Future<void> onEvent(int eventId, int ts, String deviceId) async {
    if (eventId != kHyroxLiveDoubleTapEventId) return;
    if (ts <= 0) return; // unset RTC: the offline path owns those rows
    final at = _detector.addTap(ts);
    if (at == null) return;
    try {
      await _applyBoundary(at);
    } on HyroxWriteError catch (e) {
      // A rejected boundary (floor, already-started, finalized) is a normal
      // race condition between live and offline paths — log, never throw.
      log?.call('[hyrox] live tap at $at rejected: $e');
    }
  }

  Future<void> _applyBoundary(int at) async {
    final db = await _db();
    final session = await HyroxDb.activeSession(db);
    if (session == null) return;
    if (session.status != 'armed' && session.status != 'active') return;
    final segs = session.segments;
    if (segs.isEmpty) return;
    final open = segs.where((s) => s.isOpen).toList();
    if (open.isEmpty) {
      // Nothing started yet: the burst STARTS the race (armed only — a
      // started session re-arming would be a caller bug).
      if (segs.any((s) => s.startTs != null)) return;
      await HyroxDb.startSegment(
        db: db, sessionId: session.id, ts: at, boundarySource: 'gesture',
      );
      log?.call('[hyrox] race started at $at (${session.id})');
      return;
    }
    if (open.length != 1) return;
    final cur = open.single;
    final minSec = kMinSegmentSec[cur.station] ?? 0;
    if (cur.startTs != null && at - cur.startTs! < minSec) {
      log?.call('[hyrox] tap at $at under the ${cur.station.key} floor '
          '($minSec s) — ignored');
      return;
    }
    if (cur.idx == segs.length - 1) {
      await HyroxDb.finishSegment(
        db: db, sessionId: session.id, ts: at, boundarySource: 'gesture',
      );
      log?.call('[hyrox] race finished at $at (${session.id})');
    } else {
      await HyroxDb.transitionSegment(
        db: db, sessionId: session.id, currentIdx: cur.idx,
        transitionTs: at, boundarySource: 'gesture',
      );
      log?.call('[hyrox] round ${cur.roundIndex ?? cur.idx + 1} closed at '
          '$at (${session.id})');
    }
  }
}
