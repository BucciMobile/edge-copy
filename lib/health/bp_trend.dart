// Blood-pressure trend over the IMPORTED cuff readings in
// `imported_measurement` — the one display-only use of that table beyond the
// latest-reading rows on the phone-import screen.
//
// The guard in health_measurement_import.dart / db.dart still holds in full:
// these numbers are another device's measurements, they are shown WITH the
// source app's name, they are never blended with anything this app measured,
// and nothing derived takes them as an input. A median over a cuff's own
// readings is a summary of that cuff's series, not a regression against ours
// and not a wrist-to-cuff claim — it stays on this side of the line because
// it never touches one of our series and never feeds a baseline, a tier, or a
// notification. The moment that changes, this file is the thing to delete.
//
// TREND DISPLAY ONLY, by design (see docs/FEATURES.md): no classification of
// the user, no blood-pressure verdict wording, no push. The card shows medians next to
// published guideline reference ranges and says to discuss them with a
// healthcare professional. Apple needed FDA clearance for hypertension
// notifications; a median next to a reference range is not that claim.
//
// Pure functions over rows so the pairing, the windows and the quality gates
// are testable without a database or a health store.

import 'package:flutter/foundation.dart';

import '../data/db.dart';
import 'health_measurement_import.dart';

/// Two halves of one reading may carry different uuids (HealthKit) or one
/// shared uuid with a suffix on the diastolic half (Health Connect — see
/// `rowsFrom`). When uuids do not match, timestamps within this tolerance are
/// treated as the same reading. 5 minutes: a cuff reading is one act, and two
/// manual readings five minutes apart are still one act unless the user says
/// otherwise.
const int kBpPairToleranceSec = 300;

/// A window needs at least this many PAIRED readings before any median is
/// shown. Below it the card says "not enough readings yet" — never a median
/// of one or two numbers presented as a trend.
const int kMinBpPairsPerWindow = 3;

const int kBpWindowDays30 = 30;
const int kBpWindowDays90 = 90;

/// Readings are compared at a similar time of day where possible: blood
/// pressure has a strong within-day rhythm, so a 4-hour bucket holding enough
/// readings is preferred over the all-hours mix. The bucket width is a
/// preference, not a filter — if no bucket reaches [kMinBpPairsPerWindow] the
/// whole window is used and the card says so by omission.
const int kBpSameTimeBucketHours = 4;

/// One paired reading: systolic and diastolic from the same act, with the
/// source app that recorded it (NOT NULL in the table — a reading without its
/// source is not renderable).
class BpReading {
  const BpReading({
    required this.tsSec,
    required this.systolic,
    required this.diastolic,
    required this.source,
  });

  final int tsSec;
  final double systolic;
  final double diastolic;
  final String source;
}

/// A window summary. Null windows mean "not enough readings" — never a
/// fabricated all-clear.
class BpWindow {
  const BpWindow({
    required this.n,
    required this.medianSystolic,
    required this.medianDiastolic,
    required this.sameTimeOfDay,
    required this.firstTsSec,
    required this.lastTsSec,
  });

  final int n;
  final double medianSystolic;
  final double medianDiastolic;

  /// True when the median came from a single 4-hour time-of-day bucket rather
  /// than the all-hours mix.
  final bool sameTimeOfDay;
  final int firstTsSec;
  final int lastTsSec;
}

class BpTrendSummary {
  const BpTrendSummary({
    required this.readings,
    required this.d30,
    required this.d90,
  });

  /// All paired readings, oldest first.
  final List<BpReading> readings;
  final BpWindow? d30;
  final BpWindow? d90;

  BpReading? get latest => readings.isEmpty ? null : readings.last;
}

double? medianOf(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

/// The shared-record base: Health Connect stores the diastolic half of one
/// record as `'<uuid>:bp_diastolic'` (see `rowsFrom`), so stripping that
/// suffix recovers the record id the systolic half carries.
String _baseUuid(String? uuid) {
  const suffix = ':$kKindDiastolic';
  final u = uuid ?? '';
  return u.endsWith(suffix) ? u.substring(0, u.length - suffix.length) : u;
}

double? _num(Object? v) => (v is num) ? v.toDouble() : null;
int? _ts(Object? v) => (v is num) ? v.toInt() : null;
String _str(Object? v) => (v is String) ? v : '';

BpReading? _pair(Map<String, dynamic> sys, Map<String, dynamic> dia) {
  final tsS = _ts(sys['ts']), tsD = _ts(dia['ts']);
  final s = _num(sys['value']), d = _num(dia['value']);
  if (tsS == null || tsD == null || s == null || d == null) return null;
  // Re-check the import bounds and the physiological ordering defensively: a
  // row that slipped past the importer is still a bad record, and a reading
  // with systolic <= diastolic is a cuff error code, not a measurement. Dropped,
  // not clamped — a clamped reading is a fabricated one.
  final bs = kImportedBounds[kKindSystolic]!;
  final bd = kImportedBounds[kKindDiastolic]!;
  if (s < bs.$1 || s > bs.$2 || d < bd.$1 || d > bd.$2) return null;
  if (s <= d) return null;
  // Same act, so same moment: the pair carries the systolic row's ts.
  final srcS = _str(sys['source']).trim();
  final srcD = _str(dia['source']).trim();
  return BpReading(
    tsSec: tsS,
    systolic: s,
    diastolic: d,
    source: srcS.isNotEmpty ? srcS : (srcD.isNotEmpty ? srcD : 'Unknown app'),
  );
}

/// Pair systolic and diastolic rows into readings. Shared base uuid first
/// (Health Connect), then nearest timestamp within [kBpPairToleranceSec]
/// (HealthKit gives each half its own uuid on the same correlation). Each row
/// is used in at most one pair. Result is sorted oldest first.
@visibleForTesting
List<BpReading> pairBpReadings({
  required List<Map<String, dynamic>> systolic,
  required List<Map<String, dynamic>> diastolic,
}) {
  final pairs = <BpReading>[];
  final usedSys = <String>{};
  final usedDia = <String>{};

  final sysByBase = <String, List<Map<String, dynamic>>>{};
  for (final r in systolic) {
    (sysByBase[_baseUuid(_str(r['uuid']))] ??= []).add(r);
  }
  for (final d in diastolic) {
    final base = _baseUuid(_str(d['uuid']));
    final candidates = sysByBase[base];
    if (candidates == null) continue;
    for (final s in candidates) {
      final su = _str(s['uuid']), du = _str(d['uuid']);
      if (usedSys.contains(su) || usedDia.contains(du)) continue;
      final p = _pair(s, d);
      if (p == null) continue;
      pairs.add(p);
      usedSys.add(su);
      usedDia.add(du);
      break;
    }
  }

  final remSys = [
    for (final r in systolic)
      if (!usedSys.contains(_str(r['uuid']))) r,
  ]..sort((a, b) => (_ts(a['ts']) ?? 0).compareTo(_ts(b['ts']) ?? 0));
  final remDia = [
    for (final r in diastolic)
      if (!usedDia.contains(_str(r['uuid']))) r,
  ]..sort((a, b) => (_ts(a['ts']) ?? 0).compareTo(_ts(b['ts']) ?? 0));

  var i = 0, j = 0;
  while (i < remSys.length && j < remDia.length) {
    final dt = (_ts(remSys[i]['ts']) ?? 0) - (_ts(remDia[j]['ts']) ?? 0);
    if (dt.abs() <= kBpPairToleranceSec) {
      final p = _pair(remSys[i], remDia[j]);
      if (p != null) pairs.add(p);
      i++;
      j++;
    } else if (dt < 0) {
      i++;
    } else {
      j++;
    }
  }

  pairs.sort((a, b) => a.tsSec.compareTo(b.tsSec));
  return pairs;
}

bool _inBucket(int hour, int start) =>
    ((hour - start) % 24 + 24) % 24 < kBpSameTimeBucketHours;

/// Median systolic/diastolic over the readings inside `[nowSec -
/// windowDays*86400, nowSec]`, or null when fewer than [kMinBpPairsPerWindow]
/// pairs are in the window. When a single [kBpSameTimeBucketHours]-wide
/// time-of-day bucket holds at least that many readings, the median is taken
/// over that bucket instead (same-time-of-day preference) and
/// [BpWindow.sameTimeOfDay] says so.
@visibleForTesting
BpWindow? bpWindowTrend(
  List<BpReading> pairs, {
  required int nowSec,
  required int windowDays,
}) {
  final from = nowSec - windowDays * 86400;
  final inWindow = [
    for (final p in pairs)
      if (p.tsSec >= from && p.tsSec <= nowSec) p,
  ];
  if (inWindow.length < kMinBpPairsPerWindow) return null;

  var bestCount = -1;
  List<BpReading>? best;
  for (var start = 0; start < 24; start++) {
    final sub = [
      for (final p in inWindow)
        if (_inBucket(
            DateTime.fromMillisecondsSinceEpoch(p.tsSec * 1000).hour, start)) p,
    ];
    if (sub.length > bestCount) {
      bestCount = sub.length;
      best = sub;
    }
  }
  final List<BpReading> chosen;
  var sameTime = false;
  if (best != null && bestCount >= kMinBpPairsPerWindow) {
    chosen = best;
    sameTime = true;
  } else {
    chosen = inWindow;
  }

  return BpWindow(
    n: chosen.length,
    medianSystolic: medianOf([for (final p in chosen) p.systolic])!,
    medianDiastolic: medianOf([for (final p in chosen) p.diastolic])!,
    sameTimeOfDay: sameTime,
    firstTsSec: chosen.first.tsSec,
    lastTsSec: chosen.last.tsSec,
  );
}

/// Pair both halves and compute the 30- and 90-day windows ending at
/// [nowSec]. Windows below the pair gate come back null — the caller renders
/// "not enough readings yet", not a number.
BpTrendSummary summarizeBp({
  required List<Map<String, dynamic>> systolic,
  required List<Map<String, dynamic>> diastolic,
  required int nowSec,
}) {
  final pairs = pairBpReadings(systolic: systolic, diastolic: diastolic);
  return BpTrendSummary(
    readings: pairs,
    d30: bpWindowTrend(pairs, nowSec: nowSec, windowDays: kBpWindowDays30),
    d90: bpWindowTrend(pairs, nowSec: nowSec, windowDays: kBpWindowDays90),
  );
}

/// Read both BP kinds from `imported_measurement` and summarize. Display-only
/// read of the table, the same one the phone-import screen does — never a
/// compute input.
Future<BpTrendSummary> loadBpTrend({DateTime? now}) async {
  final nowSec = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final sys = await LocalDb.importedMeasurements(kKindSystolic, limit: 2000);
  final dia = await LocalDb.importedMeasurements(kKindDiastolic, limit: 2000);
  return summarizeBp(systolic: sys, diastolic: dia, nowSec: nowSec);
}
