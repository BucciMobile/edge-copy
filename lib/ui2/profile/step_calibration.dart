// Per-user, per-activity calibration of the strap's live 100 Hz pedometer.
//
// WHAT THIS SCREEN IS FOR. The strap counts steps off its own 100 Hz IMU
// (`pedometer()` in analytics), and the count is a residual off on a real wrist
// in ways that depend on the wearer. Analytics asks for exactly this correction
// in its own `StepParams.gain` docstring: "Measure it against ground truth, per
// user, and store it with the user; never bake a population constant back in
// here."
//
// THE WEARER COUNTS, THE BAND DOES NOT. A gait routine cannot end when the band
// reaches the target: `rawSteps` would be the target by construction and every
// wearer would fit a gain of exactly 1.0 forever. So the screen asks the wearer
// to count their own steps and shows the band's live count as FEEDBACK — the gap
// between the two is the measurement they came for.
//
// Household movement is the other family, and the one that pays: at the wrist,
// arm work out-accelerates walking, which is why these devices emit 22-27 false
// steps per minute during dishes and driving (O'Connell 2017). Its reference is
// the PHONE, because nobody counts steps while doing chores, and a pocket-carried
// device is simply a better sensor for this one quantity
// (`lib/health/phone_pedometer.dart`). The correction there comes out LOW — and
// deliberately never zero, because a household routine does contain real steps.
//
// WHAT THIS SCREEN MUST NOT DO. `app_state.dart` records that a previous guided
// step calibration was removed because its only reader had been deleted and it
// "told the user their walk had taught the app something when nothing read the
// result". This one has a reader — `_bankGaitRuns` and the session checkpoint
// both bank through `creditedStepsForRun` — and this screen must not claim a
// correction took effect until that save has actually returned.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../compute/step_calibration_fit.dart';
import '../../data/db.dart';
import '../../health/phone_pedometer.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../screens/metric_detail.dart' show detailLinkRow, detailScaffold;
import '../ui2.dart';

class StepCalibrationScreen extends StatefulWidget {
  const StepCalibrationScreen({super.key});

  @override
  State<StepCalibrationScreen> createState() => _StepCalibrationScreenState();
}

class _StepCalibrationScreenState extends State<StepCalibrationScreen> {
  final Map<StepCategory, LiveStepGainProfile?> _profiles = {};
  CalibrationSession? _session;
  Timer? _ticker;
  DateTime? _routineStart;

  /// What the last routine produced, in the wearer's words. Never set before a
  /// save has returned: a message is a claim, and an unclaimed one is the exact
  /// failure the previous calibration shipped.
  String? _outcome;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadProfiles());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    for (final c in StepCategory.values) {
      _profiles[c] = await LocalDb.liveStepGainProfile(c);
    }
    if (mounted) setState(() {});
  }

  void _start(StepCategory category) {
    final app = context.read<AppState>();
    _ticker?.cancel();
    _routineStart = DateTime.now();
    setState(() {
      _outcome = null;
      _session = CalibrationSession(category: category)
        ..start(
          // Everything the routine is credited with is measured from HERE, so a
          // walk that happened before the wearer pressed start cannot land in
          // their calibration.
          bandBaseline: app.liveStrapRawSteps,
          nowMs: DateTime.now().millisecondsSinceEpoch,
        );
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final s = _session;
    if (!mounted || s == null) return;
    final app = context.read<AppState>();
    s.observe(
      bandTotal: app.liveStrapRawSteps,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    // The household family's reference is the phone. Read it as the routine
    // runs rather than only at the end, so a permission failure surfaces while
    // the wearer is still standing there instead of after three minutes.
    if (s.category.referenceIsPhone) unawaited(_readPhone(s));
    setState(() {});
  }

  Future<void> _readPhone(CalibrationSession s) async {
    final start = _routineStart;
    if (start == null) return;
    try {
      final steps = await PhonePedometer().stepsBetween(start, DateTime.now());
      // A null or -1 answer is the phone saying "I did not cover that interval",
      // which is not a zero. Leaving the reference absent makes `finish()` refuse
      // the run rather than fit a 0.0 gain from a phone on a table.
      if (steps != null && steps >= 0) s.setPhoneSteps(steps);
    } catch (_) {
      // Absent reference, not a fabricated one. finish() reports it.
    }
  }

  void _cancel() {
    _ticker?.cancel();
    setState(() {
      _session = null;
      _routineStart = null;
      _outcome = null;
    });
  }

  Future<void> _finish() async {
    final s = _session;
    if (s == null) return;
    _ticker?.cancel();
    final out = s.finish();
    final l = AppLocalizations.of(context);

    if (out.bandSilent) {
      setState(() {
        _session = null;
        _outcome = l?.stepCalNoSignal ?? 'The band recorded nothing during that routine.';
      });
      return;
    }
    if (out.refusal != null) {
      setState(() {
        _session = null;
        _outcome = _describeRefusal(out.refusal!, l);
      });
      return;
    }

    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final profile = await LocalDb.bankLiveStepCalibrationRun(
        out.run!,
        runTs: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      // Only after the save returned: a walk already in progress would otherwise
      // bank with the previous gain.
      app.invalidateLiveStepCalibration();
      await _loadProfiles();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _session = null;
        _routineStart = null;
        _outcome = _describeOutcome(out.run!, profile, l);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _session = null;
        _routineStart = null;
        _outcome = (l?.stepCalSaveFailed ?? 'Could not save that calibration.') +
            ' ($e)';
      });
    }
  }

  /// Every refusal is a claim about the ROUTINE, and the wearer is told which —
  /// a silent no-op that leaves them believing their walk taught the app
  /// something is the failure this screen exists to avoid.
  String _describeRefusal(StepRunRejection r, AppLocalizations? l) =>
      switch (r) {
        StepRunRejection.noReferenceSteps =>
          l?.stepCalNoPhone ??
              'Your phone counted no steps while you did that. Keep it in your '
                  'pocket next time — it is the reference for household movement.',
        StepRunRejection.rawTooSmall =>
          l?.stepCalBandQuiet ??
              'The band saw almost no movement. It is worth checking the strap is '
                  'worn snugly and streaming.',
        StepRunRejection.expectedTooSmall =>
          l?.stepCalTooShort ??
              'That routine was too short to measure against. Walk the full '
                  'count.',
        StepRunRejection.rawExceedsExpectedByTooMuch =>
          l?.stepCalMismatch ??
              'The band counted far more than you did. Something other than '
                  'walking was being picked up.',
        StepRunRejection.referenceWrongSource =>
          l?.stepCalWrongSource ?? 'That routine used the wrong reference.',
        StepRunRejection.nonFiniteFeature =>
          l?.stepCalBadData ?? 'That routine produced unreadable sensor data.',
      };

  String _describeOutcome(
    StepCalibrationRun run,
    LiveStepGainProfile profile,
    AppLocalizations? l,
  ) {
    final pct = ((profile.gain - 1) * 100).round();
    final sign = pct >= 0 ? '+' : '';
    if (run.category.isGait) {
      return (l?.stepCalDoneGait ??
              'Saved. You counted {count} steps and the band saw {band}. From '
                  'now on this kind of walking is corrected by {pct}%.')
          .replaceAll('{count}', '${run.expectedSteps}')
          .replaceAll('{band}', '${run.rawSteps}')
          .replaceAll('{pct}', '$sign$pct');
    }
    return (l?.stepCalDoneHousehold ??
            'Saved. Your phone counted {count} steps of the {band} the band '
                'saw. Household movement is now scaled to {gain}.')
        .replaceAll('{count}', '${run.expectedSteps}')
        .replaceAll('{band}', '${run.rawSteps}')
        .replaceAll('{gain}', profile.gain.toStringAsFixed(2));
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final s = _session;
    return detailScaffold(
      c,
      l?.stepCalTitle ?? 'Step calibration',
      s == null ? _overview(c, l) : _running(c, l, s),
    );
  }

  List<Widget> _overview(BuildContext c, AppLocalizations? l) {
    final p = P.of(c);
    return [
      Text(
        l?.stepCalIntro ??
            'Your strap counts steps off its own motion sensor, and how far off '
                'it is depends on you. These routines measure that. Nothing '
                'leaves your phone.',
        style: F.cap.copyWith(color: p.ink2, height: 1.5),
      ),
      if (_outcome != null) ...[
        const SizedBox(height: S.x4),
        _feedback(c, _outcome!),
      ],
      const SizedBox(height: S.x4),
      for (final category in StepCategory.values) ...[
        detailLinkRow(
          c,
          _iconFor(category),
          _titleFor(category, l),
          _subtitleFor(category, l),
          () => _start(category),
        ),
        const SizedBox(height: S.x3),
      ],
    ];
  }

  List<Widget> _running(BuildContext c, AppLocalizations? l, CalibrationSession s) {
    final p = P.of(c);
    final isHousehold = s.category.referenceIsPhone;
    return [
      Text(
        _guideFor(s.category, l),
        style: F.cap.copyWith(color: p.ink2, height: 1.5),
      ),
      const SizedBox(height: S.x5),
      // The band's LIVE count, labelled as the band's — never as progress the
      // wearer should trust as their own count.
      Center(
        child: Text(
          '${s.bandRawSteps}',
          style: F.display.copyWith(color: p.ink),
        ),
      ),
      const SizedBox(height: S.x2),
      Center(
        child: Text(
          (l?.stepCalBandSeen ?? 'steps the band has seen')
              .replaceAll('{target}',
                  isHousehold ? '' : '${s.targetSteps}'),
          style: F.cap.copyWith(color: p.ink2),
        ),
      ),
      const SizedBox(height: S.x4),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: s.progress,
          minHeight: 6,
          backgroundColor: p.track,
          valueColor: AlwaysStoppedAnimation<Color>(p.ink),
        ),
      ),
      const SizedBox(height: S.x2),
      Text(
        isHousehold
            ? (l?.stepCalElapsed ?? 'Keep going — this one is timed.')
            : (l?.stepCalCountYourself ??
                'Count your own steps. Stop when you reach {target}.')
                .replaceAll('{target}', '${s.targetSteps}'),
        style: F.cap.copyWith(color: p.ink2),
      ),
      const SizedBox(height: S.x6),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : _cancel,
              child: Text(l?.stepCalCancel ?? 'Cancel'),
            ),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: FilledButton(
              onPressed: (_busy || !s.canFinish) ? null : _finish,
              child: Text(l?.stepCalFinish ?? 'Done'),
            ),
          ),
        ],
      ),
      if (!s.canFinish) ...[
        const SizedBox(height: S.x2),
        Text(
          isHousehold
              ? (l?.stepCalKeepMoving ??
                  'Nothing recorded yet — keep the phone on you and keep moving.')
              : (l?.stepCalKeepWalking ??
                  'Nothing recorded yet — start walking with the strap snug.'),
          style: F.cap.copyWith(color: p.ink2),
        ),
      ],
    ];
  }

  Widget _feedback(BuildContext c, String text) {
    final p = P.of(c);
    return Container(
      padding: const EdgeInsets.all(S.x4),
      decoration: BoxDecoration(
        color: p.ink3.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: F.cap.copyWith(color: p.ink, height: 1.5)),
    );
  }

  IconData _iconFor(StepCategory category) => switch (category) {
        StepCategory.slow => LucideIcons.footprints,
        StepCategory.brisk => LucideIcons.personStanding,
        StepCategory.jog => LucideIcons.activity,
        StepCategory.everyday => LucideIcons.house,
      };

  String _titleFor(StepCategory category, AppLocalizations? l) =>
      switch (category) {
        StepCategory.slow => l?.stepCalSlowTitle ?? 'Slow walk',
        StepCategory.brisk => l?.stepCalBriskTitle ?? 'Brisk walk',
        StepCategory.jog => l?.stepCalJogTitle ?? 'Jog',
        StepCategory.everyday => l?.stepCalEverydayTitle ?? 'Around the house',
      };

  String _subtitleFor(StepCategory category, AppLocalizations? l) {
    final profile = _profiles[category];
    final state = profile?.isCalibrated ?? false
        ? (l?.stepCalCalibrated ?? 'Calibrated — counted {n} times')
            .replaceAll('{n}', '${profile!.nRuns}')
        : (l?.stepCalNotCalibrated ?? 'Not calibrated yet');
    return '$state · ${_guideShort(category, l)}';
  }

  String _guideShort(StepCategory category, AppLocalizations? l) =>
      switch (category) {
        StepCategory.slow =>
          l?.stepCalSlowSub ?? 'walk slowly, phone in your pocket',
        StepCategory.brisk => l?.stepCalBriskSub ?? 'walk at your usual pace',
        StepCategory.jog => l?.stepCalJogSub ?? 'jog steadily',
        StepCategory.everyday =>
          l?.stepCalEverydaySub ?? 'tidy up for three minutes, phone in pocket',
      };

  String _guideFor(StepCategory category, AppLocalizations? l) =>
      switch (category) {
        StepCategory.slow =>
          l?.stepCalSlowGuide ??
              'Walk slowly and evenly, strap snug. Count 100 steps yourself.',
        StepCategory.brisk =>
          l?.stepCalBriskGuide ??
              'Walk at your normal pace. Count 100 steps yourself.',
        StepCategory.jog =>
          l?.stepCalJogGuide ?? 'Jog steadily. Count 100 steps yourself.',
        StepCategory.everyday =>
          l?.stepCalEverydayGuide ??
              'Do ordinary things around the house — carry, lift, tidy — with '
                  'your phone in your pocket. Three minutes. Do not pace '
                  'deliberately.',
      };
}
