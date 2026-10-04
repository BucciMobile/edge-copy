// A band's OWN hypnogram as a main-sleep source (`vendor_staged`).
//
// Precedence in `calendarDays`: user override > vendor_staged > auto >
// auto_fallback > none. Stages arrive already mapped to our `stages4` words
// (each adapter owns its one mapping function), and are banked in
// `vendor_sleep_epoch`, never in `observation`. A night is only used when
// [vendorNightRejection] has nothing against it; otherwise it stays stored and
// unused.

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart' as ana;

/// One 30 s (or longer) epoch the band staged, in epoch seconds, half-open.
class VendorEpoch {
  final int startSec;
  final int endSec;

  /// 'wake' | 'light' | 'deep' | 'rem'.
  final String stage;
  const VendorEpoch(this.startSec, this.endSec, this.stage);
}

/// One night of one device's epochs, as `vendor_sleep_epoch` groups them.
class VendorNight {
  final String deviceId;
  final String source;
  final int decodedAtSec;

  /// Sorted by [VendorEpoch.startSec].
  final List<VendorEpoch> epochs;
  const VendorNight({
    required this.deviceId,
    required this.source,
    required this.decodedAtSec,
    required this.epochs,
  });

  int get onsetSec => epochs.first.startSec;
  int get offsetSec => epochs.last.endSec;
}

/// Page-boundary jitter tolerated between consecutive epochs.
const int kVendorEpochJitterSec = 60;
const int kVendorNightMinSec = 3 * 3600;
const int kVendorNightMaxSec = 14 * 3600;

/// A night where one stage holds at least this share is not a hypnogram.
const double kVendorDegenerateShare = 0.9;

/// Why [n] must not stage a night, or null when it may.
///
/// [dataStartSec]/[dataEndSec] bound the substrate the night would be staged
/// over; [ours] is the window our own detection (accel-led or HR-led) found,
/// null when it found none. The decoder behind these epochs is unverified on
/// some rings, so every check is a structural one a wrong layout would fail.
String? vendorNightRejection(
  VendorNight n, {
  required int dataStartSec,
  required int dataEndSec,
  required ({int onsetSec, int offsetSec})? ours,
}) {
  if (n.epochs.isEmpty) return 'empty';
  for (var i = 0; i < n.epochs.length; i++) {
    final e = n.epochs[i];
    if (e.endSec <= e.startSec) return 'bad_epoch';
    if (i == 0) continue;
    final gap = e.startSec - n.epochs[i - 1].endSec;
    if (gap < -kVendorEpochJitterSec) return 'overlap';
    if (gap > kVendorEpochJitterSec) return 'gap';
  }
  final len = n.offsetSec - n.onsetSec;
  if (len < kVendorNightMinSec || len > kVendorNightMaxSec) return 'length';
  if (n.onsetSec < dataStartSec ||
      n.offsetSec > dataEndSec ||
      n.offsetSec > n.decodedAtSec) {
    return 'outside_data';
  }
  final share = <String, int>{};
  for (final e in n.epochs) {
    share.update(e.stage, (s) => s + e.endSec - e.startSec,
        ifAbsent: () => e.endSec - e.startSec);
  }
  if (share.values.reduce(math.max) >= len * kVendorDegenerateShare) {
    return 'degenerate';
  }
  if (ours == null) return 'no_own_sleep';
  final overlap = math.min(n.offsetSec, ours.offsetSec) -
      math.max(n.onsetSec, ours.onsetSec);
  if (overlap < len ~/ 2) return 'no_overlap';
  return null;
}

/// [forced] (our segmentation forced onto [n]'s window) with every stage
/// figure replaced by [n]'s epochs. The window, confidence and indices stay
/// ours; a second no epoch covers is 'unobserved'.
ana.SleepSegmentation vendorStagedSegmentation(
  ana.SleepSegmentation forced,
  VendorNight n,
) {
  final win = forced.window;
  final onsetMs = win?.onsetMs;
  if (win == null || onsetMs == null) return forced;
  final start = onsetMs ~/ 1000;
  final inBed = forced.stages4.length;
  final s4 = List<String>.filled(inBed, 'unobserved');
  for (final e in n.epochs) {
    for (var t = math.max(e.startSec, start);
        t < math.min(e.endSec, start + inBed);
        t++) {
      s4[t - start] = e.stage;
    }
  }
  var tst = 0, light = 0, deep = 0, rem = 0, wake = 0, unobserved = 0;
  var first = -1, last = -1;
  for (var i = 0; i < inBed; i++) {
    switch (s4[i]) {
      case 'unobserved':
        unobserved++;
        continue;
      case 'wake':
        wake++;
        continue;
      case 'light':
        light++;
      case 'deep':
        deep++;
      case 'rem':
        rem++;
    }
    tst++;
    if (first < 0) first = i;
    last = i;
  }
  if (tst == 0) return ana.SleepSegmentation.absent;
  var waso = 0, awakenings = 0, longest = 0, run = 0, wakeRun = 0;
  for (var i = 0; i < inBed; i++) {
    final asleep = s4[i] != 'wake' && s4[i] != 'unobserved';
    run = asleep ? run + 1 : 0;
    if (run > longest) longest = run;
    if (s4[i] == 'wake' && i > first && i < last) {
      waso++;
      wakeRun++;
      if (wakeRun == ana.kSustainedAwakeningSec) awakenings++;
    } else {
      wakeRun = 0;
    }
  }
  final observed = inBed - unobserved;
  return ana.SleepSegmentation(
    window: win,
    stages: [
      for (final s in s4)
        s == 'rem'
            ? ana.SleepStage.rem
            : (s == 'light' || s == 'deep'
                ? ana.SleepStage.nrem
                : ana.SleepStage.wake),
    ],
    stages4: s4,
    tstSec: tst,
    wasoSec: waso,
    inBedSec: inBed,
    unobservedSec: unobserved,
    efficiencyPct: observed > 0 ? 100.0 * tst / observed : null,
    nremSec: light + deep,
    lightSec: light,
    deepSec: deep,
    remSec: rem,
    wakeSec: wake,
    sustainedAwakenings: awakenings,
    longestSleepRunSec: longest,
    confidence: forced.confidence,
  );
}
