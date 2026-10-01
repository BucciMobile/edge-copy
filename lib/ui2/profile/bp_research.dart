// BP research capture — DEVELOPER MODE ONLY.
//
// One flow: take a cuff blood pressure reading, type the pair in, press
// capture. The app freezes the band's own decoded data around the
// MEASUREMENT instant — by default the 5 minutes of rest BEFORE the
// measurement, so the cuff's own inflation stays out of the feature window
// — next to the reference pair, and keeps every capture so a human can
// compare them over weeks: here in a list, or out of the app through the
// `bp_research` CSV export set.
//
// The measurement instant can be back-dated: a cuff reading taken this
// morning and typed in this evening is paired with the historical sensor
// data of the MEASUREMENT time, never with whatever the band holds at
// entry time.
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
  final _sessionId = TextEditingController();
  // Optional back-dating: 'HH:MM' today or 'YYYY-MM-DD HH:MM'. Empty means
  // the measurement is being taken right now.
  final _measuredAt = TextEditingController();
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
    _sessionId.dispose();
    _measuredAt.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final rows = await LocalDb.bpResearchCaptures();
    if (mounted) setState(() => _rows = rows);
  }

  /// Parse the optional measurement-time field. Returns null when empty
  /// (= now) or unparseable (the caller refuses the capture: a wrong
  /// pairing instant silently pairs the reference with the wrong five
  /// minutes of band data — worse than refusing).
  DateTime? _parseMeasuredAt(DateTime now) {
    final text = _measuredAt.text.trim();
    if (text.isEmpty) return now;
    final twoPart = RegExp(r'^(\d{4}-\d{2}-\d{2})[ T](\d{1,2}):(\d{2})$');
    final m = twoPart.firstMatch(text);
    if (m != null) {
      final d = DateTime.tryParse('${m.group(1)} ${m.group(2)}:${m.group(3)}');
      return d;
    }
    final hm = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text);
    if (hm != null) {
      final h = int.tryParse(hm.group(1)!);
      final min = int.tryParse(hm.group(2)!);
      if (h == null || min == null || h > 23 || min > 59) return null;
      return DateTime(now.year, now.month, now.day, h, min);
    }
    return null;
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
              'That pair is outside the range this app supports \u2014 '
              'check the numbers and try again. Nothing was stored.'),
        ));
      }
      return;
    }
    final enteredAt = DateTime.now();
    final measuredAt = _parseMeasuredAt(enteredAt);
    if (measuredAt == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Could not read the measurement time \u2014 use HH:MM or '
              'YYYY-MM-DD HH:MM, or leave it empty for "now". Nothing was '
              'stored.'),
        ));
      }
      return;
    }
    final measuredAtMs = measuredAt.millisecondsSinceEpoch;
    final enteredAtMs = enteredAt.millisecondsSinceEpoch;
    if (measuredAtMs > enteredAtMs + 60 * 1000) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'The measurement time lies in the future \u2014 the window '
              'would pair the reference with data that does not exist yet. '
              'Nothing was stored.'),
        ));
      }
      return;
    }
    setState(() => _busy = true);
    var stored = false;
    try {
      // The rest window BEFORE the measurement: the feature window ends at
      // the measurement start, so the cuff's own inflation stays out of it
      // by construction. See lib/health/bp_research_capture.dart.
      final start = measuredAtMs - kResearchRestPreMs;
      final end = measuredAtMs + kResearchWindowPostMs;
      final db = await LocalDb.instance;
      // Read exactly what the app already holds around the MEASUREMENT
      // instant — historical rows for a back-dated capture. Two narrow
      // range reads, never a day dump, never the raw archive.
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
        measuredAtMs: measuredAtMs,
        onehzRows: onehz,
        rrRows: rr,
        nowMs: enteredAtMs,
      );
      await LocalDb.putBpResearchCapture(
        BpResearchCapture(
          measuredAtMs: measuredAtMs,
          // The measurement START is the instant the features are anchored
          // to; the nominal instant stays the idempotency key.
          measurementStartedAtMs: measuredAtMs,
          // A single-instant cuff reading has no invented duration.
          measurementFinishedAtMs: null,
          systolicMmHg: sys,
          diastolicMmHg: dia,
          capturedAtMs: enteredAtMs,
          device: _device.text.trim().isEmpty ? null : _device.text.trim(),
          posture: _posture.text.trim().isEmpty ? null : _posture.text.trim(),
          conditions:
              _conditions.text.trim().isEmpty ? null : _conditions.text.trim(),
          bandDeviceId: LocalDb.kPrimaryDeviceId,
          measurementSessionId:
              _sessionId.text.trim().isEmpty ? null : _sessionId.text.trim(),
          window: window,
        ),
        snapshotOnehzRows: onehz,
        snapshotRrRows: rr,
      );
      stored = true;
      _sys.clear();
      _dia.clear();
      _measuredAt.clear();
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
                'press capture. The band data of the minutes before that '
                'instant is frozen next to it \u2014 for you to compare outside '
                'this app. Nothing here is a health feature, nothing here '
                'feeds any score, and nothing here is ever blended with what '
                'the band measured.',
            style: F.cap.copyWith(color: p.ink2, height: 1.5),
          ),
          const SizedBox(height: S.x4),
          TextField(
            controller: _sys,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))
            ],
            decoration: InputDecoration(
              labelText: l?.bpResearchSystolic ?? 'Systolic (mmHg)',
            ),
          ),
          const SizedBox(height: S.x2),
          TextField(
            controller: _dia,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))
            ],
            decoration: InputDecoration(
              labelText: l?.bpResearchDiastolic ?? 'Diastolic (mmHg)',
            ),
          ),
          const SizedBox(height: S.x2),
          TextField(
            controller: _measuredAt,
            keyboardType: TextInputType.datetime,
            decoration: const InputDecoration(
              labelText:
                  'Measurement time (HH:MM or YYYY-MM-DD HH:MM; empty = now)',
              helperText:
                  'Back-date to the actual cuff reading \u2014 the band window '
                  'is frozen around THAT instant, not around typing it in.',
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
            controller: _sessionId,
            decoration: const InputDecoration(
              labelText: 'Session id (optional)',
              helperText:
                  'Group readings of one sitting \u2014 they are not '
                  'independent states, and an analysis must be able to tell.',
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
            Text(l?.bpResearchHistory ?? 'Captures', style: F.head),
            const SizedBox(height: S.x2),
            for (final r in _rows)
              ListTile(
                dense: true,
                title: Text(
                  '${r['systolic_mmhg']}/${r['diastolic_mmhg']} mmHg \u2014 '
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
                  'Export all captures as CSV from Your data \u203a Export CSV '
                  '(set \u201cBP research captures\u201d). This is the dedicated '
                  'export for BP research data; a full-database backup or an '
                  'opt-in health share also contains it.',
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
    final status = r['quality_status'];
    if (onehz == null && beats == null) {
      return 'No band data in the window \u2014 stored as-is.';
    }
    final parts = <String>[];
    if (hr is num) parts.add('HR ${hr.toStringAsFixed(0)} bpm');
    if (rmssd is num) parts.add('RMSSD ${rmssd.toStringAsFixed(0)} ms');
    parts.add('${onehz ?? 0} 1 Hz rows, ${beats ?? 0} beats');
    if (status is String && status.isNotEmpty && status != 'ok') {
      parts.add(status);
    }
    return parts.join(' \u00b7 ');
  }
}
