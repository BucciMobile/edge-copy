// tier_card.dart — the tier/deviation card shared by Home and Health.
//
// Follows the existing illness-card pattern exactly: the verdict is dated by
// the night it is about, only today's or yesterday's shows (calendar gate,
// DST-safe via isRecentFindingDate), and an undated or stale verdict shows
// nothing — never "last night" by assumption. While the illness state is
// active (the user answered "Sick / symptoms"), the deviation is expected, so
// the card says the watches are standing down instead of re-warning. While
// the baseline is still learning (stage < 3, nothing to report), Health shows
// the calibration progress honestly — "learning your baseline — 23 of 30
// nights" — and never a green-by-silence card.

import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../compute/findings.dart' show isRecentFindingDate;
import '../../compute/tier_engine.dart';
import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';

/// Whether the explicit illness state is active (the user answered
/// "Sick / symptoms" and it has not auto-expired or been dismissed).
Future<bool> illnessStateActive() async {
  try {
    final raw = await LocalDb.getCursor('illness_state');
    if (raw == null) return false;
    return IllnessState.fromJson(jsonDecode(raw)).active;
  } catch (_) {
    return false;
  }
}

String _signalName(AppLocalizations? l, String s) => switch (s) {
      'rhr' => l?.workoutRestingHeartRateLabel ?? 'Resting heart rate',
      'hrv' => 'HRV',
      'resp' => l?.healthRowRespRate ?? 'Respiratory rate',
      'temp' => l?.signalSkinTempRaw ?? 'Skin temperature',
      _ => s,
    };

/// The tier card, or null when there is honestly nothing to show.
///
/// [tiers] is the cross-day bundle's `tiers` block; [today] is the wall-clock
/// day at build time. [showCalibration] (Health) also renders the
/// "learning your baseline" card while stage < 3 and nothing fired.
Widget? tierCard(
  BuildContext c,
  Object? tiers, {
  required String today,
  bool showCalibration = false,
  bool illnessActive = false,
}) {
  if (tiers is! Map) return null;
  final l = AppLocalizations.of(c);
  final date = tiers['date'];
  if (date is! String || !isRecentFindingDate(date, today: today)) return null;
  final tier = (tiers['tier'] as num?)?.toInt() ?? 0;
  final stage = (tiers['stage'] as num?)?.toInt() ?? 0;
  final valid = (tiers['valid_nights'] as num?)?.toInt() ?? 0;
  final streak = (tiers['streak'] as num?)?.toInt() ?? 1;
  final signals = <String>[
    for (final s in (tiers['signals'] as List? ?? const []))
      if (s is String) s,
  ];

  if (tier >= 1 && illnessActive) {
    return Observation(
      l?.tierCardIllnessActiveTitle ?? 'Taking it easy',
      l?.tierCardIllnessActive ??
          "You told us you're not feeling well — the overnight watches are standing down while that lasts.",
      advice: l?.tierCardAdvice ?? 'Worth resting if it continues past a couple of days.',
    );
  }
  if (tier >= 1) {
    final names = [for (final s in signals) _signalName(l, s)].join(', ');
    return Observation(
      l?.tierCardTitle ?? 'Off your usual baseline',
      (l?.tierCardBody(names, streak) ??
          '$names deviated from your baseline for $streak nights. A pattern, not a cause.'),
      advice: tier >= 3
          ? (l?.tierCardAdviceTier3 ??
              'Consider rest, and if this persists, consider checking with a healthcare professional.')
          : (l?.tierCardAdvice ??
              'Worth resting if it continues past a couple of days.'),
    );
  }
  if (showCalibration && stage < 3) {
    return Observation(
      l?.tierCardCalibratingTitle ?? 'Learning your baseline',
      l?.tierCardCalibrating(valid) ??
          'Learning your baseline — $valid of 30 nights so far.',
      advice: l?.tierCardCalibratingAdvice ??
          'The overnight watches stay quiet until they have enough of your nights.',
    );
  }
  return null;
}
