// checkin_sheet.dart — the in-app half of the ask-first check-in.
//
// The tier-2/3 push asks a QUESTION ("do you feel unusually tired or run
// down?") — never a diagnosis. On Android the three replies ride as inline
// notification action buttons; on iOS (no push actions) the notification tap
// lands here, at /checkin?date=…&tier=…, with the same three one-tap answers.
// Every reply goes through handleCheckInReply (auto-journals it, applies the
// damping / illness state). [onReply] is injectable so tests can observe the
// reply without touching the database.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../notify/checkin.dart';
import '../ui2.dart';

class CheckInSheet extends StatelessWidget {
  const CheckInSheet({
    super.key,
    required this.date,
    required this.tier,
    this.onReply,
  });

  /// The night the check-in is about ('YYYY-MM-DD').
  final String date;

  /// 2 or 3.
  final int tier;

  /// Test seam: defaults to the real handler (journal + cursors).
  final Future<void> Function(CheckInReply reply)? onReply;

  Future<void> _reply(BuildContext c, CheckInReply r) async {
    final handler = onReply ?? ((reply) => handleCheckInReply(reply, date));
    await handler(r);
    if (c.mounted) Navigator.of(c).pop();
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    final labels = <CheckInReply, String>{
      CheckInReply.fine: l?.checkInActionFine ?? 'I feel fine',
      CheckInReply.runDown: l?.checkInActionRunDown ?? 'A bit run down',
      CheckInReply.sick: l?.checkInActionSick ?? 'Sick / symptoms',
    };
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(S.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: S.x6),
              Text(
                l?.journalComposeHowAreYouFeeling ?? 'How are you feeling?',
                style: F.t2.copyWith(color: p.ink),
              ),
              const SizedBox(height: S.x2),
              Text(
                l?.checkInSheetBody ??
                    'Your values have deviated from your usual for the last few nights.',
                style: F.body.copyWith(color: p.ink2, height: 1.5),
              ),
              const SizedBox(height: S.x6),
              for (final r in CheckInReply.values) ...[
                Surface(
                  onTap: () => _reply(c, r),
                  child: Text(
                    labels[r]!,
                    style: F.body.copyWith(color: p.on(C.domMind)),
                  ),
                ),
                const SizedBox(height: S.x3),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
