// ONE-SHOT, RAW-FREE — naps that were really the start of the next night.
//
// Before v106 a sleep begun before midnight was also booked as that day's nap
// (`PreparedDerivationDay.tonightSleepOnsetSec` fixed it for new derives). Days
// derived earlier keep the double count in `naps` and `nap_min`, and most of
// them have no raw left to re-derive from. Every stored bundle does carry both
// halves of the answer: its own naps and the next day's main window. So the
// overlap is dropped from the stored bundle, in place, once.

import 'dart:convert';

import '../data/day_label.dart';
import '../data/db.dart';
import 'nap_edits.dart' show napMinutes;

/// `compute_freshness` key marking the cleanup as applied.
const String kNapNextNightCleanupKey = 'nap_next_night_cleanup_v1';

/// Last algo version that could book tonight's sleep as a nap.
const int kNapNextNightFixedIn = 106;

/// [naps] without the detected ones overlapping the next day's main sleep
/// [nextOnsetSec, nextOffsetSec). A nap the user logged (it carries a
/// `source`) is kept. Null when nothing is dropped.
List<Map<String, dynamic>>? napsWithoutNextNight(
  List<Map<String, dynamic>> naps,
  int nextOnsetSec,
  int nextOffsetSec,
) {
  final kept = [
    for (final n in naps)
      if (n['source'] != null ||
          n['start'] is! num ||
          n['end'] is! num ||
          (n['end'] as num) <= nextOnsetSec ||
          (n['start'] as num) >= nextOffsetSec)
        n,
  ];
  return kept.length == naps.length ? null : kept;
}

/// Runs the cleanup once over every stored day below [kNapNextNightFixedIn].
/// Returns the days rewritten. Marked done only after it finishes.
Future<int> cleanNextNightNapsOnce() async {
  if (await LocalDb.computeFreshness(kNapNextNightCleanupKey) != null) return 0;
  final versions = await LocalDb.dayResultVersions();
  final days = versions.keys.toList()..sort();
  var cleaned = 0;
  for (final day in days) {
    if (versions[day]! >= kNapNextNightFixedIn) continue;
    // Calendar arithmetic on the label (noon avoids any DST edge).
    final d = DateTime.parse(day);
    final nextDay = dayLabelOf(DateTime(d.year, d.month, d.day + 1, 12));
    if (!versions.containsKey(nextDay)) continue;
    final row = await LocalDb.dayResult(day);
    final payload = _decode(row?['payload_json']);
    final naps = (payload?['naps'] as Map?)?['value'];
    if (payload == null || naps is! List || naps.isEmpty) continue;
    final win = (((_decode((await LocalDb.dayResult(nextDay))?['payload_json'])
                ?['sleep'] as Map?)?['window'] as Map?)?['value']) as Map?;
    final on = win?['onset_ms'], off = win?['offset_ms'];
    if (on is! num || off is! num) continue;
    final kept = napsWithoutNextNight(
      [for (final n in naps) if (n is Map) n.cast<String, dynamic>()],
      on ~/ 1000,
      off ~/ 1000,
    );
    if (kept == null) continue;
    (payload['naps'] as Map)
      ..['value'] = kept
      ..['count'] = kept.length;
    final napMin = napMinutes(kept).toDouble();
    final scalars = payload['scalars'];
    if (scalars is Map) scalars['nap_min'] = napMin;
    // The trend reads `metric_series`; same value, same order as the readiness
    // backfill (series first, bundle second).
    await LocalDb.putMetricSeriesValue(day, 'nap_min', napMin);
    await LocalDb.rewriteDayPayload(
      day,
      (row!['algo_version'] as num).toInt(),
      jsonEncode(payload),
    );
    cleaned++;
  }
  await LocalDb.putComputeFreshness(
      kNapNextNightCleanupKey, jsonEncode({'cleaned': cleaned}));
  return cleaned;
}

Map<String, dynamic>? _decode(Object? json) {
  if (json is! String) return null;
  try {
    final v = jsonDecode(json);
    return v is Map ? v.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}
