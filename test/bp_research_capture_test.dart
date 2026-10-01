// Unit tests for the pure window computation behind the BP research capture.
//
// The rules under test are the ones the storage and UI lean on:
//   · a window with no band data is NULL, not zeroes;
//   · a stat the window cannot honestly compute (no valid HR, no
//     CONTIGUOUS interval pair for RMSSD) is absent, never zero;
//   · rows outside the window are ignored, whatever their table's epoch
//     base is (decoded_onehz.rec_ts is SECONDS, decoded_rr.rr_ts_ms is ms);
//   · the v2 rest window lies BEFORE the measurement instant: the cuff's
//     own inflation stays out of the feature window by construction;
//   · duplicate timestamps are deduplicated, unsorted rows are sorted;
//   · RMSSD never spans a sensor gap, and the gap fraction is reported;
//   · a window whose end lies in the future is 'pending';
//   · requested window bounds and OBSERVED data bounds are distinct.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/health/bp_research_capture.dart';

void main() {
  const at = 1700000000000; // ms
  // The v2 default rest window: [at − 5 min, at].
  const preStart = at - 5 * 60 * 1000;

  test('no band data in the window yields a NULL window, not zeroes', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: const [],
      rrRows: const [],
    );
    expect(w, isNull);
  });

  test('the rest window lies BEFORE the measurement, inflation excluded',
      () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        // Inside the rest window (seconds base).
        {'rec_ts': preStart ~/ 1000 + 60, 'hr': 60},
        // The measurement instant itself and AFTER it: the cuff inflating.
        // Outside the v2 window — must not land in any stat.
        {'rec_ts': at ~/ 1000 + 1, 'hr': 180},
      ],
      rrRows: const [],
    );
    expect(w, isNotNull);
    expect(w!.windowStartMs, preStart);
    expect(w.windowEndMs, at);
    expect(w.onehzRows, 1);
    expect(w.hrMean, 60.0);
  });

  test('rows outside the window are ignored (seconds vs ms bases)', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        // rec_ts is epoch SECONDS. Inside the rest window.
        {'rec_ts': preStart ~/ 1000 + 10, 'hr': 60},
        // 10 minutes before the window: outside, must not land in any stat.
        {'rec_ts': preStart ~/ 1000 - 600, 'hr': 180},
      ],
      rrRows: [
        // rr_ts_ms is epoch MS. Inside.
        {'rr_ts_ms': preStart + 1000, 'rr_ms': 1000},
      ],
    );
    expect(w, isNotNull);
    expect(w!.onehzRows, 1);
    expect(w.hrMean, 60.0);
    expect(w.rrBeats, 1);
    expect(w.rmssdMs, isNull); // one beat forms no successive difference
  });

  test('unsorted rows are sorted; duplicate timestamps deduplicated', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        {'rec_ts': preStart ~/ 1000 + 30, 'hr': 64},
        // Same second twice — one row, not two.
        {'rec_ts': preStart ~/ 1000 + 10, 'hr': 56},
        {'rec_ts': preStart ~/ 1000 + 10, 'hr': 56},
      ],
      rrRows: [
        {'rr_ts_ms': preStart + 3000, 'rr_ms': 900},
        // Same instant twice — one interval, not two.
        {'rr_ts_ms': preStart + 1000, 'rr_ms': 1000},
        {'rr_ts_ms': preStart + 1000, 'rr_ms': 1000},
      ],
    );
    expect(w!.onehzRows, 2);
    expect(w.rrBeats, 2);
    expect(w.hrMean, 60.0); // (56 + 64) / 2
  });

  test('invalid HR rows do not drag the mean toward zero', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        {'rec_ts': preStart ~/ 1000, 'hr': 0},
        {'rec_ts': preStart ~/ 1000 + 1, 'hr': 58},
        {'rec_ts': preStart ~/ 1000 + 2, 'hr': 62},
        // Non-finite junk: rejected outright.
        {'rec_ts': preStart ~/ 1000 + 3, 'hr': -5},
      ],
      rrRows: const [],
    );
    expect(w!.onehzRows, 4);
    expect(w.validHrSeconds, 2);
    expect(w.hrMean, 60.0); // 0 and −5 excluded, not averaged in
  });

  test('RMSSD over successive differences, min/max preserved', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: const [],
      rrRows: [
        {'rr_ts_ms': preStart + 1000, 'rr_ms': 1000},
        {'rr_ts_ms': preStart + 2000, 'rr_ms': 1100},
        {'rr_ts_ms': preStart + 3000, 'rr_ms': 900},
      ],
    );
    expect(w!.rrBeats, 3);
    expect(w.rrMsMin, 900.0);
    expect(w.rrMsMax, 1100.0);
    // diffs: +100, −200 → sqrt((100² + 200²)/2) = sqrt(25000) = 158.11…
    expect(w.rmssdMs!, closeTo(158.11, 0.01));
    expect(w.validIntervalCount, 3);
    expect(w.validIntervalPairCount, 2);
    expect(w.hrMean, isNull); // no 1 Hz rows: absent, not zero
  });

  test('RMSSD never spans a sensor gap; the gap fraction is reported', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: const [],
      rrRows: [
        // A contiguous pair before the gap.
        {'rr_ts_ms': preStart + 1000, 'rr_ms': 1000},
        {'rr_ts_ms': preStart + 2000, 'rr_ms': 1100},
        // THE GAP: two minutes of nothing. The pair across it must not
        // enter RMSSD — a difference across a sensor gap is a fabricated
        // HRV sample, not a real one.
        {'rr_ts_ms': preStart + 140000, 'rr_ms': 800},
        // A contiguous pair after the gap.
        {'rr_ts_ms': preStart + 141000, 'rr_ms': 850},
      ],
    );
    expect(w!.rrBeats, 4);
    expect(w.validIntervalCount, 4);
    // Two of three successive pairs are contiguous; one spans the gap.
    expect(w.validIntervalPairCount, 2);
    expect(w.rejectedIntervalFraction, closeTo(1 / 3, 0.001));
    // RMSSD over the two REAL pairs: diffs +100, −50 → sqrt((10000+2500)/2).
    expect(w.rmssdMs!, closeTo(_sqrtRef(12500 / 2), 0.01));
    // One rejected pair of three is under the >50% gap threshold, and no
    // 1 Hz rows means coverage is NULL (absent) rather than low — so the
    // honest verdict is 'ok', with the gap fraction carried alongside.
    expect(w.qualityStatus, 'ok');
  });

  test('a window whose end lies in the future is pending', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        {'rec_ts': preStart ~/ 1000, 'hr': 60},
      ],
      rrRows: const [],
      nowMs: at - 60000, // "now" is a minute before the measurement
    );
    expect(w!.qualityStatus, 'pending');
  });

  test('a well-covered window is ok; coverage is honest', () {
    // 300 valid seconds of a 300-second window = full coverage.
    final onehz = [
      for (var i = 0; i < 300; i++)
        {'rec_ts': preStart ~/ 1000 + i, 'hr': 60},
    ];
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: onehz,
      rrRows: const [],
    );
    expect(w!.qualityStatus, 'ok');
    expect(w.coverageFraction, closeTo(1.0, 0.001));
    expect(w.validHrSeconds, 300);
    expect(w.featureVersion, kResearchFeatureVersion);
  });

  test('requested bounds and observed bounds are distinct', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        {'rec_ts': preStart ~/ 1000 + 120, 'hr': 60},
        {'rec_ts': preStart ~/ 1000 + 180, 'hr': 62},
      ],
      rrRows: const [],
    );
    // Requested: the full 5 minutes. Observed: 60 s in the middle.
    expect(w!.windowStartMs, preStart);
    expect(w.windowEndMs, at);
    expect(w.observedStartMs, preStart + 120000);
    expect(w.observedEndMs, preStart + 180000);
    expect(w.coverageFraction, closeTo(2 / 300, 0.001));
  });

  test('a custom postMs window can include the measurement itself', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        {'rec_ts': at ~/ 1000 + 30, 'hr': 70}, // after the instant: inside now
      ],
      rrRows: const [],
      postMs: 60000,
    );
    expect(w!.windowEndMs, at + 60000);
    expect(w.onehzRows, 1);
  });
}

double _sqrtRef(double v) => v <= 0 ? 0 : _newton(v);
double _newton(double v) {
  var x = v;
  var y = (x + 1) / 2;
  while ((y - x).abs() > 1e-12) {
    x = y;
    y = (x + v / x) / 2;
  }
  return y;
}
