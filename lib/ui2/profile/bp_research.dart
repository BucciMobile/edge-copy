// BP research capture — DEVELOPER MODE ONLY.
//
// One flow: take a cuff blood pressure reading, type the pair in, press
// capture. The app freezes the band's own decoded data from the ±2 minutes
// around that instant (1 Hz HR, R-R intervals) next to the reference pair,
// and keeps every capture so a human can compare them over weeks — here in
// a list, or out of the app through the `bp_research` CSV export set.
//
// This is data COLLECTION, not a blood pressure feature:
//   · Nothing derived reads these tables. No score, no baseline, no chart
//     of ours takes a capture as an input.
//   · Nothing here is ever blended with, averaged against, or corrected
//     against anything the band measured.
//   · Nothing here is exported to HealthKit / Health Connect.
// A window with no band data is stored as a capture with an EMPTY window —
// missing is missing, never zero.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/db.dart';
import '../../health/bp_research_capture.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'devices.dart' show formatDayTime;

class BpResearchScreen extends StatefulWidget {
  const BpResearchScreen({super.key});

  @override
  State<BpResearchScreen> createState() => _BpResearchScreenState();
}

class _BpResearchScreenState extends State<BpResearchScreen> {
  final _sys = TextEditingController();
  final _dia = TextEditingController();
  final _device = TextEditingController();
  final _posture = TextEditingController();
  final _conditions = TextEditingController();
  List<Map<String, Object?>> _rows = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _sys.dispose();
    _dia.dispose();
    _device.dispose();
    _posture.dispose();
    _conditions.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final rows = await LocalDb.bpResearchCaptures();
    if (mounted) setState(() => _rows = rows);
  }

  Future<void> _capture() async {
    if (_busy) return;
    final sys = double.tryParse(_sys.text);
    final dia = double.tryParse(_dia.text);
    final l = AppLocalizations.of(context);
    if (sys == null ||
        dia == null ||
        sys < kResearchSystolicBounds.$1 ||
        sys > kResearchSystolicBounds.$2 ||
        dia < kResearchDiastolicBounds.$1 ||
        dia > kResearchDiastolicBounds.$2 ||
        dia >= sys) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l?.bpResearchBadValue ??
              'That pair is not a blood pressure — check the numbers and '
              'try again. Nothing was stored.'),
        ));
      }
      return;
    }
    setState(() => _busy = true);
    var stored = false;
    try {
      final now = DateTime.now();
      final start = now.millisecondsSinceEpoch - kBpResearchWindowPreMs;
      final end = now.millisecondsSinceEpoch + kBpResearchWindowPostMs;
      final db = await LocalDb.instance;
      // Read exactly what the app already holds around the instant. Two
      // narrow range reads — never a day dump, never the raw archive.
      final onehz = await db.rawQuery(
        'SELECT rec_ts, hr FROM decoded_onehz '
        'WHERE device_id = ? AND rec_ts >= ? AND rec_ts <= ? '
        'ORDER BY rec_ts ASC',
        [LocalDb.kPrimaryDeviceId, start ~/ 1000, end ~/ 1000],
      );
      final rr = await db.rawQuery(
        'SELECT rr_ts_ms, rr_ms FROM decoded_rr '
        'WHERE device_id = ? AND rr_ts_ms >= ? AND rr_ts_ms <= ? '
        'ORDER BY rr_ts_ms ASC',
        [LocalDb.kPrimaryDeviceId, start, end],
      );
      final window = researchWindowFrom(
        measuredAtMs: now.millisecondsSinceEpoch,
        onehzRows: onehz,
        rrRows: rr,
      );
      await LocalDb.putBpResearchCapture(BpResearchCapture(
        measuredAtMs: now.millisecondsSinceEpoch,
        systolicMmHg: sys,
        diastolicMmHg: dia,
        capturedAtMs: now.millisecondsSinceEpoch,
        device: _device.text.trim().isEmpty ? null : _device.text.trim(),
        posture: _posture.text.trim().isEmpty ? null : _posture.text.trim(),
        conditions:
            _conditions.text.trim().isEmpty ? null : _conditions.text.trim(),
        window: window,
      ));
      stored = true;
      _sys.clear();
      _dia.clear();
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(stored
              ? 'Capture saved, but refreshing the history failed. ($e)'
              : 'Capture failed \u2014 nothing was stored. ($e)'),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    return Scaffold(
      appBar: AppBar(
        title: Text(l?.bpResearchTitle ?? 'BP research capture'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(S.x4),
        children: [
          Text(
            l?.bpResearchIntro ??
                'EXPERIMENTAL. Take a cuff reading, type the pair in, '
                'press capture. The band data of the ±2 minutes around that '
                'instant is frozen next to it — for you to compare outside '
                'this app. Nothing here is a health feature, nothing here '
                'feeds any score, and nothing here is ever blended with what '
                'the band measured.',
            style: F.cap.copyWith(color: p.ink2, height: 1.5),
          ),
          const SizedBox(height: S.x4),
          TextField(
            controller: _sys,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
            decoration: InputDecoration(
              labelText: l?.bpResearchSystolic ?? 'Systolic (mmHg)',
            ),
          ),
          const SizedBox(height: S.x2),
          TextField(
            controller: _dia,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
            decoration: InputDecoration(
              labelText: l?.bpResearchDiastolic ?? 'Diastolic (mmHg)',
            ),
          ),
          const SizedBox(height: S.x2),
          TextField(
            controller: _device,
            decoration: InputDecoration(
              labelText: l?.bpResearchDevice ?? 'Cuff device (optional)',
            ),
          ),
          const SizedBox(height: S.x2),
          TextField(
            controller: _posture,
            decoration: InputDecoration(
              labelText: l?.bpResearchPosture ?? 'Posture (optional)',
            ),
          ),
          const SizedBox(height: S.x2),
          TextField(
            controller: _conditions,
            decoration: InputDecoration(
              labelText: l?.bpResearchConditions ?? 'Conditions (optional)',
            ),
          ),
          const SizedBox(height: S.x4),
          FilledButton.icon(
            onPressed: _busy ? null : _capture,
            icon: const Icon(LucideIcons.plus),
            label: Text(l?.bpResearchCapture ?? 'Capture now'),
          ),
          const SizedBox(height: S.x6),
          if (_rows.isNotEmpty) ...[
            Text(l?.bpResearchHistory ?? 'Captures',
                style: F.head),
            const SizedBox(height: S.x2),
            for (final r in _rows)
              ListTile(
                dense: true,
                title: Text(
                  '${r['systolic_mmhg']}/${r['diastolic_mmhg']} mmHg — '
                  '${formatDayTime(DateTime.fromMillisecondsSinceEpoch(
                      r['measured_at_ms'] as int), l)}',
                ),
                subtitle: Text(_windowSummary(r)),
                trailing: IconButton(
                  icon: const Icon(LucideIcons.trash2, size: 18),
                  onPressed: () async {
                    await LocalDb.deleteBpResearchCapture(r['id'] as int);
                    await _refresh();
                  },
                ),
              ),
            const SizedBox(height: S.x4),
            Text(
              l?.bpResearchExportHint ??
                  'Export all captures as CSV from Your data › Export CSV '
                  '(set “BP research captures”). Research data — it never '
                  'leaves the phone except through that file.',
              style: F.cap.copyWith(color: p.ink2, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  /// A window is summarised as what it actually holds. A NULL stat is shown
  /// as absent — a dash, never a zero, and never a value that would read as
  /// a measurement.
  static String _windowSummary(Map<String, Object?> r) {
    final onehz = r['onehz_rows'];
    final beats = r['rr_beats'];
    final hr = r['hr_mean'];
    final rmssd = r['rmssd_ms'];

    if (onehz == null && beats == null) {
      return 'No band data in the window — stored as-is.';
    }
    final parts = <String>[];
    if (hr is num) parts.add('HR ${hr.toStringAsFixed(0)} bpm');
    if (rmssd is num) parts.add('RMSSD ${rmssd.toStringAsFixed(0)} ms');
    parts.add('${onehz ?? 0} 1 Hz rows, ${beats ?? 0} beats');
    return parts.join(' · ');
  }
}
