// HYROX screen — arm a race, watch the live rounds, correct boundaries after
// the fact, finish or mark DNF. All writes go through HyroxController ->
// HyroxDb; the band taps land via HyroxLiveTapHandler and the offline
// reconciler, this screen only reads + triggers the phone-side fallback.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../data/db.dart';
import '../../data/hyrox_plan.dart';
import '../../data/hyrox_store.dart';
import '../../state/hyrox_controller.dart';
import '../ui2.dart';

class HyroxScreen extends StatelessWidget {
  const HyroxScreen({super.key});

  @override
  Widget build(BuildContext c) {
    return ChangeNotifierProvider(
      create: (_) => HyroxController(() => LocalDb.instance)..refresh(),
      child: const _HyroxBody(),
    );
  }
}

class _HyroxBody extends StatelessWidget {
  const _HyroxBody();

  @override
  Widget build(BuildContext c) {
    final h = c.watch<HyroxController>();
    final s = h.session;
    return Scaffold(
      appBar: AppBar(title: const Text('HYROX')),
      body: ListView(
        padding: const EdgeInsets.all(S.x4),
        children: [
          if (h.error != null)
            StatusCard('Something went wrong', '$h.error',
                icon: LucideIcons.triangleAlert),
          if (s == null) ...[
            const Text('No HYROX session yet. Arm a race to start tracking '
                'rounds — tap the band three times at each round change, or '
                'use the button below.'),
            const SizedBox(height: S.x4),
            for (final p in kHyroxPresets.take(2))
              Padding(
                padding: const EdgeInsets.only(bottom: S.x2),
                child: FilledButton(
                  onPressed: () => h.arm(p),
                  child: Text('Arm $p'),
                ),
              ),
          ] else ...[
            _StatusLine(s),
            const SizedBox(height: S.x3),
            if (h.isActive) ...[
              FilledButton.icon(
                onPressed: () => h.tap(),
                icon: const Icon(LucideIcons.pointer),
                label: const Text('Next round (tap)'),
              ),
              const SizedBox(height: S.x2),
              TextButton(
                onPressed: () => h.markAbandoned(),
                child: const Text('DNF — stop here'),
              ),
              TextButton(
                onPressed: () => h.discard(),
                child: const Text('Discard session'),
              ),
            ] else if (s.status == 'finished' || s.status == 'abandoned') ...[
              FilledButton(
                onPressed: () => h.finalize(),
                child: const Text('Save race'),
              ),
            ],
            const SizedBox(height: S.x4),
            _RoundList(h, s),
          ],
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine(this.s);
  final HyroxSession s;

  @override
  Widget build(BuildContext c) {
    final total = s.totalSec;
    final moving = s.movingSec;
    final pause = s.pauseSec;
    String fmt(int? v) =>
        v == null ? '—' : '${v ~/ 60}:${(v % 60).toString().padLeft(2, '0')}';
    return Wrap(spacing: S.x4, runSpacing: S.x2, children: [
      Chip(label: Text(s.status)),
      Chip(label: Text('total ${fmt(total)}')),
      Chip(label: Text('moving ${fmt(moving)}')),
      Chip(label: Text('pause ${fmt(pause)}')),
    ]);
  }
}

class _RoundList extends StatelessWidget {
  const _RoundList(this.h, this.s);
  final HyroxController h;
  final HyroxSession s;

  @override
  Widget build(BuildContext c) {
    String fmt(int? v) =>
        v == null ? '—' : '${v ~/ 60}:${(v % 60).toString().padLeft(2, '0')}';
    return Column(children: [
      for (final seg in s.segments)
        Card(
          child: ListTile(
            leading: CircleAvatar(
                child: Text('${seg.roundIndex ?? seg.idx + 1}')),
            title: Text(seg.station.key.replaceAll('_', ' ')),
            subtitle: Text(
              '${fmt(seg.durationSec)} · ${seg.boundarySource}'
              '${seg.plannedDistanceM != null ? ' · ${seg.plannedDistanceM!.toStringAsFixed(0)} m plan' : ''}'
              '${seg.plannedReps != null ? ' · ${seg.plannedReps} reps plan' : ''}',
            ),
            trailing: h.isActive && seg.startTs != null && seg.endTs != null
                ? PopupMenuButton<String>(
                    onSelected: (v) async {
                      // Post-hoc correction: move this boundary 60 s earlier
                      // as the demo action; a full time picker is follow-up.
                      if (v == 'move') {
                        await h.adjustBoundary(seg.idx - 1, seg.startTs! - 60);
                      } else if (v == 'merge') {
                        await h.removeBoundary(seg.idx - 1);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'move', child: Text('Move boundary −60 s')),
                      PopupMenuItem(value: 'merge', child: Text('Merge with previous')),
                    ],
                  )
                : null,
          ),
        ),
    ]);
  }
}
