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
      l?.tierCardTitle ?? 'Off your usual',
      (l?.tierCardBody(names, streak) ??
          '$names deviated from your usual for $streak nights. A pattern, not a cause.'),
      advice: tier >= 3
          ? (l?.tierCardAdviceTier3 ??
              'Consider rest, and if this persists, consider checking with a healthcare professional.')
          : (l?.tierCardAdvice ??
              'Worth resting if it continues past a couple of days.'),
    );
  }
  if (showCalibration && stage < 3) {
    return Observation(
      l?.tierCardCalibratingTitle ?? 'Learning your usual',
      l?.tierCardCalibrating(valid) ??
          'Learning your usual — $valid of 30 nights so far.',
      advice: l?.tierCardCalibratingAdvice ??
          'The overnight watches stay quiet until they have enough of your nights.',
    );
  }
  return null;
}

/// The PR-3 informational cards (inactivity watch + recovery trend), read from
/// the cross-day bundle's `inactivity` / `recovery_trend` blocks
/// (activity_watch.dart). Both are card-only — neither ever pushes — and both
/// ride the same today/yesterday freshness gate as the tier card. While the
/// illness state is active the recovery trend stands down (the deviations are
/// expected) and the inactivity watch stays quiet too. Nothing fires off a
/// stale date, and a block that is not 'firing' shows nothing — never green.
List<Widget> trendCards(
  BuildContext c, {
  required String today,
  Object? inactivity,
  Object? recoveryTrend,
  bool illnessActive = false,
}) {
  final l = AppLocalizations.of(c);
  final out = <Widget>[];

  if (!illnessActive && inactivity is Map && inactivity['state'] == 'firing') {
    final date = inactivity['date'];
    if (date is String && isRecentFindingDate(date, today: today)) {
      final days = (inactivity['days_below'] as num?)?.toInt() ?? 0;
      final strain7 = (inactivity['strain7'] as num?)?.round() ?? 0;
      final goal = (inactivity['goal'] as num?)?.round() ?? 0;
      out.add(Observation(
        l?.inactivityCardTitle ?? 'Well below your usual activity',
        l?.inactivityCardBody(days, strain7, goal) ??
            'Your activity has been below your usual for $days days — $strain7 strain in the last 7 days against your $goal weekly goal.',
        advice: l?.inactivityCardAdvice ?? 'Just a note — no action needed.',
      ));
    }
  }

  if (!illnessActive &&
      recoveryTrend is Map &&
      recoveryTrend['state'] == 'firing') {
    final date = recoveryTrend['date'];
    if (date is String && isRecentFindingDate(date, today: today)) {
      final days = (recoveryTrend['days_suppressed'] as num?)?.toInt() ?? 0;
      // PR 4: the trend can fire on the performance-decrement path (pace per
      // heartbeat slipping at normal load) instead of the HRV/RHR path.
      final via = recoveryTrend['via']?.toString();
      final pct =
          (((recoveryTrend['economy_delta_pct'] as num?)?.toDouble() ?? 0) *
                  100)
              .round();
      // On the performance path the relevant day count is the days with an
      // economy reading, not the HRV-suppressed nights.
      final perfDays =
          (recoveryTrend['days_economy'] as num?)?.toInt() ?? days;
      final body = via == 'performance'
          ? (l?.recoveryCardPerfBody(perfDays, pct) ??
              'Your pace per heartbeat has slipped about $pct% over the last $perfDays days while your training load stayed normal — a pattern in your own data, not a verdict on you.')
          : (l?.recoveryCardBody(days) ??
              'HRV has run below your usual for $days nights and your resting heart rate has crept up, while your training load stayed normal.');
      out.add(Observation(
        l?.recoveryCardTitle ?? 'Recovery trend below your usual',
        body,
        advice: l?.recoveryCardAdvice ??
            'Lighter days and earlier nights until it lifts.',
      ));
    }
  }

  return out;
}
