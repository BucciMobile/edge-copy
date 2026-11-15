// checkin.dart — the ask-first check-in's quick replies.
//
// The tier-2/3 push (tier_engine.dart) ASKS a question ("do you feel unusually
// tired or run down?") instead of telling, because self-report outperforms
// objective wearable metrics for early detection (Saw et al., BJSM 2016).
// Every reply is handled the same way, from an Android action button or the
// in-app sheet:
//
//   * "I feel fine"     → damp the detector family for 48 h (cursor
//                         `checkin_damp_until`) and journal the reply, so the
//                         same family does not re-ask tomorrow.
//   * "A bit run down"  → journal the reply, keep watching (no damping).
//   * "Sick / symptoms" → activate the explicit illness state (cursor
//                         `illness_state`): while it is active the
//                         illness-signature deviations are treated as EXPECTED
//                         and the check-in stands down; the state
//                         auto-expires after 3 clean nights or on dismissal.
//
// Every reply writes a journal entry automatically (merged into the day's
// existing entry, never overwriting it) — the same mechanism the gesture
// "mark a moment" uses. Journal tags stay in the canonical English vocabulary.

import 'dart:convert';

import '../compute/tier_engine.dart' show IllnessState, kDampSeconds;
import '../data/db.dart';

/// The three quick replies.
enum CheckInReply { fine, runDown, sick }

/// Action-button id grammar: `checkin:<reply>:<date>` ('YYYY-MM-DD').
String checkInActionId(CheckInReply reply, String date) =>
    'checkin:${reply.name}:$date';

/// Parse an action-button id back to its reply + date, or null.
({CheckInReply reply, String date})? parseCheckInActionId(String id) {
  if (!id.startsWith('checkin:')) return null;
  final parts = id.split(':');
  if (parts.length != 3 || parts[2].isEmpty) return null;
  for (final r in CheckInReply.values) {
    if (r.name == parts[1]) return (reply: r, date: parts[2]);
  }
  return null;
}

/// Journal note per reply. Stored data, not UI copy — stays in English like
/// the AI journal writer's notes.
String _noteFor(CheckInReply r) => switch (r) {
      CheckInReply.fine => 'check-in: felt fine',
      CheckInReply.runDown => 'check-in: a bit run down',
      CheckInReply.sick => 'check-in: reported symptoms',
    };

/// Handle one quick reply about the night labeled [date]: auto-journal it,
/// then apply the reply's effect (damping / illness state).
Future<void> handleCheckInReply(CheckInReply reply, String date) async {
  // ── auto-journal: merge into the day's existing entry, never overwrite ──
  try {
    final rows = await LocalDb.journalRows(sinceDaysEpoch: date);
    var tagsJson = '[]';
    var note = '';
    for (final r in rows) {
      if (r['date'] == date) {
        tagsJson = (r['tags_json'] as String?) ?? '[]';
        note = (r['note'] as String?) ?? '';
      }
    }
    final tags = <String>[];
    try {
      final d = jsonDecode(tagsJson);
      if (d is List) {
        for (final t in d) {
          if (t is String && t.isNotEmpty) tags.add(t);
        }
      }
    } catch (_) {
      // Malformed tags blob -> start from empty, never crash the reply.
    }
    if (reply == CheckInReply.sick && !tags.contains('sick')) {
      tags.add('sick');
    }
    final add = _noteFor(reply);
    note = note.isEmpty ? add : '$note • $add';
    await LocalDb.putJournal(date, jsonEncode(tags), note);
  } catch (_) {
    // The journal write is best-effort; the reply's effect below still lands.
  }

  // ── the reply's effect ──
  try {
    if (reply == CheckInReply.fine) {
      final until = DateTime.now().secondsSinceEpoch + kDampSeconds;
      await LocalDb.setCursor('checkin_damp_until', until.toString());
    } else if (reply == CheckInReply.sick) {
      final raw = await LocalDb.getCursor('illness_state');
      Object? dec;
      if (raw != null) {
        try {
          dec = jsonDecode(raw);
        } catch (_) {
          dec = null;
        }
      }
      final state = IllnessState.fromJson(dec).activate(date);
      await LocalDb.setCursor('illness_state', jsonEncode(state.toJson()));
    }
    // runDown: journaled above; the watch keeps watching.
  } catch (_) {
    // Cursors are best-effort too — a failed write must not crash the sheet.
  }
}
