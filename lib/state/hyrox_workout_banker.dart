// hyrox_workout_banker.dart — banks every CLOSED HYROX round as a real
// `sessions` row and links it to the segment (workout_id).
//
// Why: routes, zones, splits, derived analytics and the Apple Health export
// all read `sessions`. A HYROX round is indoor and GPS-less, so it is banked
// as type 'other' (the neutral non-route catalogue key) with source 'manual'
// — the same provenance value the live workout controller stamps on
// band-recorded sessions. The segment row stays the source of truth for the
// race timeline; the sessions row exists so the round shows up everywhere a
// workout shows up, including Health export via the existing path.
//
// Idempotent: segments that already carry a workout_id are skipped, so this
// is safe to call after every live transition AND after every reconciler run.

import 'package:sqflite/sqflite.dart';

import '../data/db.dart';
import '../data/hyrox_store.dart';

class HyroxWorkoutBanker {
  HyroxWorkoutBanker._();

  /// Bank every closed, not-yet-linked round of [sessionId].
  ///
  /// Returns the workout ids it linked. A segment whose `sessions` row cannot
  /// be written (e.g. it would overlap sleep in the activity store) is skipped
  /// and logged — the race timeline itself is never at risk, only that round's
  /// workout card.
  static Future<List<String>> bankClosedSegments(
    Database db,
    String sessionId, {
    void Function(String line)? log,
  }) async {
    final segs = await HyroxDb.segments(db, sessionId);
    final linked = <String>[];
    for (final s in segs) {
      if (s.startTs == null || s.endTs == null || s.workoutId != null) {
        continue;
      }
      final wid = '${sessionId}:r$s.idx';
      try {
        await LocalDb.putSession({
          'id': wid,
          'start_ts': s.startTs,
          'end_ts': s.endTs,
          'type': 'other',
          'status': 'done',
          'source': 'manual',
          'private': 0,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
        await HyroxDb.linkWorkout(db, sessionId, s.idx, wid);
        linked.add(wid);
        log?.call('[hyrox] banked round ${s.roundIndex ?? s.idx + 1} as $wid');
      } catch (e) {
        log?.call('[hyrox] banking round ${s.idx} of $sessionId failed: $e');
      }
    }
    return linked;
  }

  /// Convenience for the two call sites (live taps, reconciler): bank whatever
  /// closed segments the active session has right now. Never throws.
  static Future<void> bankActive(
    Database db, {
    void Function(String line)? log,
  }) async {
    try {
      final session = await HyroxDb.activeSession(db);
      if (session == null) return;
      if (session.status != 'armed' && session.status != 'active') return;
      await bankClosedSegments(db, session.id, log: log);
    } catch (e) {
      log?.call('[hyrox] banking skipped: $e');
    }
  }
}
