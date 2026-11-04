// hyrox_controller.dart — ChangeNotifier backing the HYROX screen: arming,
// live round view, post-hoc corrections and the result. All writes go through
// HyroxDb; the controller only holds the session id and refreshes on change.

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../data/hyrox_plan.dart';
import '../data/hyrox_store.dart';

class HyroxController extends ChangeNotifier {
  HyroxController(this._db);

  final Future<Database> Function() _db;

  String? _sessionId;

  /// The session shown on the screen (active first, else newest finalized).
  HyroxSession? session;
  Object? error;

  String? get sessionId => _sessionId;
  bool get isActive =>
      session != null && !session!.isFinalized && session!.status != 'discarded';

  Future<void> refresh() async {
    try {
      final db = await _db();
      // Active session first; else keep showing the one the user is looking
      // at (a just-discarded race must stay visible as discarded); else the
      // newest finalized race.
      session = await HyroxDb.activeSession(db);
      if (session == null && _sessionId != null) {
        session = await HyroxDb.byId(db, _sessionId!);
      }
      session ??= (await HyroxDb.finalized(db, limit: 1)).firstOrNull;
      _sessionId = session?.id ?? _sessionId;
      error = null;
    } catch (e) {
      error = e;
    }
    notifyListeners();
  }

  /// Arm a new race: discard nothing, create a fresh armed session.
  Future<void> arm(String preset) async {
    final db = await _db();
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'hyrox_${now.toRadixString(36)}';
    final plan = HyroxPlan.race(preset);
    await HyroxDb.create(db, HyroxSession(
      id: id,
      kind: 'race',
      preset: preset,
      status: 'armed',
      plan: plan,
      createdAt: now,
      updatedAt: now,
    ));
    _sessionId = id;
    await refresh();
  }

  /// Arm a free-form training session.
  Future<void> armTraining(List<HyroxSegmentPlan> segments) async {
    final db = await _db();
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'hyrox_${now.toRadixString(36)}';
    await HyroxDb.create(db, HyroxSession(
      id: id,
      kind: 'training',
      preset: 'hyrox_training',
      status: 'armed',
      plan: HyroxPlan.training(segments),
      createdAt: now,
      updatedAt: now,
    ));
    _sessionId = id;
    await refresh();
  }

  /// On-screen fallback for a band tap: same burst semantics are the band's
  /// job; here a single button press is one boundary.
  Future<void> tap() async {
    final db = await _db();
    final s = session;
    if (s == null || _sessionId == null) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final segs = s.segments;
    final open = segs.where((x) => x.isOpen).toList();
    if (open.isEmpty) {
      if (segs.any((x) => x.startTs != null)) return;
      await HyroxDb.startSegment(
          db: db, sessionId: _sessionId!, ts: now, boundarySource: 'phone');
    } else if (open.length == 1) {
      final cur = open.single;
      if (cur.idx == segs.length - 1) {
        await HyroxDb.finishSegment(
            db: db, sessionId: _sessionId!, ts: now, boundarySource: 'phone');
      } else {
        await HyroxDb.transitionSegment(
          db: db, sessionId: _sessionId!, currentIdx: cur.idx,
          transitionTs: now, boundarySource: 'phone');
      }
    }
    await refresh();
  }

  Future<void> adjustBoundary(int idx, int newTs) async {
    final db = await _db();
    if (_sessionId == null) return;
    await HyroxDb.adjustBoundary(
        db: db, sessionId: _sessionId!, idx: idx, newTs: newTs);
    await refresh();
  }

  Future<void> adjustStart(int newTs) async {
    final db = await _db();
    if (_sessionId == null) return;
    await HyroxDb.adjustStart(db: db, sessionId: _sessionId!, newTs: newTs);
    await refresh();
  }

  Future<void> removeBoundary(int idx) async {
    final db = await _db();
    if (_sessionId == null) return;
    await HyroxDb.removeBoundary(db: db, sessionId: _sessionId!, idx: idx);
    await refresh();
  }

  Future<void> markAbandoned() async {
    final db = await _db();
    final s = session;
    if (s == null || _sessionId == null) return;
    await HyroxDb.updateSession(db, HyroxSession(
      id: s.id, kind: s.kind, preset: s.preset, status: 'abandoned',
      plan: s.plan, createdAt: s.createdAt, updatedAt: s.updatedAt,
    ));
    await refresh();
  }

  Future<void> finalize() async {
    final db = await _db();
    if (_sessionId == null) return;
    await HyroxDb.finalize(db, _sessionId!);
    await refresh();
  }

  Future<void> discard() async {
    final db = await _db();
    final s = session;
    if (s == null || _sessionId == null) return;
    await HyroxDb.updateSession(db, HyroxSession(
      id: s.id, kind: s.kind, preset: s.preset, status: 'discarded',
      plan: s.plan, createdAt: s.createdAt, updatedAt: s.updatedAt,
    ));
    await refresh();
  }

  Future<void> show(String id) async {
    _sessionId = id;
    await refresh();
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
