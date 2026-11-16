// The blood-pressure trend card on Health › Overview: 30/90-day medians of
// the IMPORTED cuff readings (imported_measurement), shown next to published
// guideline reference ranges.
//
// DISPLAY ONLY, and that is a hard line, not a style: no classification of the
// user, no hypertension wording, no push, and the numbers never feed anything
// derived (the guard in health_measurement_import.dart holds — see
// lib/health/bp_trend.dart). The card states what the cuff measured, how many
// readings the median rests on, and where to discuss it. A window with fewer
// than 3 readings shows "not enough readings yet" — never a median of one.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../health/bp_trend.dart';
import '../../health/health_import_state.dart' show storeName;
import '../../l10n/app_localizations.dart';
import '../profile/devices.dart' show formatDayTime;
import '../ui2.dart';

/// "Omron Connect · Thu 4 Sep, 07:12" — the source is not decoration: a
/// reading this app did not take, shown without saying who did, is a reading
/// this app is implicitly claiming.
String _sourceLine(BpReading r, AppLocalizations? l) {
  final when = formatDayTime(
      DateTime.fromMillisecondsSinceEpoch(r.tsSec * 1000), l);
  return [r.source, when].join(' · ');
}

String _bp(BpWindow w) =>
    '${w.medianSystolic.round()}/${w.medianDiastolic.round()}';

String _windowSub(AppLocalizations? l, BpWindow w) => [
      if (l != null)
        l.bpCardReadingsCount(w.n)
      else
        '${w.n} readings',
      if (w.sameTimeOfDay)
        l?.bpCardSameTimeOfDay ?? 'taken at a similar time of day',
    ].join(' · ');

/// The section. [onRead] opens the phone-import screen (the only place BP
/// readings are pulled in); null hides the button.
Widget bpTrendSection(
  BuildContext c,
  BpTrendSummary s, {
  VoidCallback? onRead,
}) {
  final p = P.of(c);
  final l = AppLocalizations.of(c);
  final latest = s.latest;
  final d30 = s.d30, d90 = s.d90;
  return Section(
    l?.bpCardTitle(storeName) ?? 'Blood pressure from $storeName',
    Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (latest != null) ...[
            MetricRow(
              LucideIcons.stethoscope,
              C.teal,
              l?.bpCardLatest ?? 'Latest reading',
              '${latest.systolic.round()}/${latest.diastolic.round()}',
              unit: 'mmHg',
              sub: _sourceLine(latest, l),
            ),
            const SizedBox(height: S.x3),
          ],
          if (d30 != null) ...[
            MetricRow(
              LucideIcons.chartLine,
              C.blue,
              l?.bpCardMedian30 ?? 'Median, last 30 days',
              _bp(d30),
              unit: 'mmHg',
              sub: _windowSub(l, d30),
            ),
            const SizedBox(height: S.x3),
          ],
          if (d90 != null) ...[
            MetricRow(
              LucideIcons.chartLine,
              C.blue,
              l?.bpCardMedian90 ?? 'Median, last 90 days',
              _bp(d90),
              unit: 'mmHg',
              sub: _windowSub(l, d90),
            ),
            const SizedBox(height: S.x3),
          ],
          if (d30 == null && s.readings.isNotEmpty)
            StatusCard(
              l?.bpCardNotEnoughTitle ?? 'Not enough readings for a trend yet',
              l?.bpCardNotEnoughBody(s.readings.length) ??
                  'A 30-day trend needs at least 3 readings; '
                  '${s.readings.length} '
                  '${s.readings.length == 1 ? 'is' : 'are'} in so far.',
              icon: LucideIcons.clock,
            ),
          if (d30 == null && s.readings.isNotEmpty)
            const SizedBox(height: S.x3),
          Text(
            l?.bpCardReferenceRanges ??
                'Guideline reference ranges: about 130/80 mmHg (ACC/AHA) and '
                '140/90 mmHg (ESC).',
            style: F.cap.copyWith(color: p.ink3, height: 1.5),
          ),
          const SizedBox(height: S.x2),
          Text(
            l?.bpCardReferenceNote ??
                'Those are population reference points, not a verdict about '
                'you. If readings like these are common for you, discuss them '
                'with a healthcare professional.',
            style: F.cap.copyWith(color: p.ink3, height: 1.5),
          ),
          if (onRead != null) ...[
            const SizedBox(height: S.x4),
            BigButton(
              l?.phoneImportReadFrom(storeName) ?? 'Read from $storeName',
              icon: LucideIcons.stethoscope,
              color: C.teal,
              soft: true,
              onTap: onRead,
            ),
          ],
        ],
      ),
    ),
  );
}
