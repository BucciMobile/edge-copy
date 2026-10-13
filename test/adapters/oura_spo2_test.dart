// The Oura SpO2 path's pure contract: decode, percent validation,
// batch-independent summary, and the eligibility gate. Expectations are
// INDEPENDENT — hand-computed, never derived from the production
// functions under test.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/oura_spo2.dart';

OuraSpo2Event _spo2Event(List<int> body) =>
    OuraSpo2Event(kOuraEvtSpo2, 1000, Uint8List.fromList(body));

void main() {
  group('decodeOuraSpo2 (protocol-main contract)', () {
    test('valid samples with a zero and a trailing continuation marker', () {
      final event = _spo2Event([0x01, 97, 0, 96, 98, 0xff]);
      final d = decodeOuraSpo2(event);
      expect(d, isNotNull);
      expect(d!.values, [97, 0, 96, 98]);
      expect(d.continues, isTrue);
    });

    test('valid samples without a continuation marker', () {
      final event = _spo2Event([0x02, 95, 94]);
      final d = decodeOuraSpo2(event);
      expect(d, isNotNull);
      expect(d!.values, [95, 94]);
      expect(d.continues, isFalse, reason: 'no marker: the run ended here');
    });

    test('a sample over 100 refuses the whole event', () {
      final event = _spo2Event([0x01, 97, 101, 98]);
      expect(decodeOuraSpo2(event), isNull);
    });

    test('only header and marker carries no sample and is refused', () {
      final event = _spo2Event([0x01, 0xff]);
      expect(decodeOuraSpo2(event), isNull);
    });

    test('only a header byte is refused (body under two bytes)', () {
      final event = _spo2Event([0x01]);
      expect(decodeOuraSpo2(event), isNull);
    });

    test('an empty body is refused', () {
      final event = _spo2Event([]);
      expect(decodeOuraSpo2(event), isNull);
    });

    test('the wrong tag is refused', () {
      final event =
          OuraSpo2Event(0x6e, 1000, Uint8List.fromList([0x01, 97, 98]));
      expect(decodeOuraSpo2(event), isNull);
    });

    test('all zeros means a measurement-free event, kept verbatim', () {
      final event = _spo2Event([0x01, 0, 0, 0]);
      final d = decodeOuraSpo2(event);
      expect(d, isNotNull);
      expect(d!.values, [0, 0, 0]);
      expect(d.continues, isFalse);
    });

    test('a marker at the ONLY sample position leaves no samples', () {
      // [header, 0xff] is header+marker: refused above. [0x01, 0xff, 0xff]
      // strips one marker, leaving [0xff] as a "sample" over 100 — refused.
      final event = _spo2Event([0x01, 0xff, 0xff]);
      expect(decodeOuraSpo2(event), isNull);
    });
  });

  group('spo2PercentOrNull (percent contract)', () {
    test('97 with unit % is 97.0', () {
      expect(spo2PercentOrNull(97, unit: '%'), 97.0);
    });

    test('a fraction 0.97 passes through UNCHANGED — never auto-scaled to 97', () {
      // The contract is: no scale guessing. 0.97 with unit '%' is in (0,100],
      // so it passes the validator AS 0.97 percent — which is why the ONLY
      // writer of rows is the decoder whose unit contract is known ('%' means
      // integer percent 0..100 from the ring), and this test pins that the
      // helper never multiplies by 100 to "fix" a magnitude.
      final v = spo2PercentOrNull(0.97, unit: '%');
      expect(v, 0.97);
      expect(v, isNot(97.0));
    });

    test('null value or non-percent unit is not a percentage', () {
      expect(spo2PercentOrNull(null, unit: '%'), isNull);
      expect(spo2PercentOrNull(97, unit: 'spo2'), isNull);
      expect(spo2PercentOrNull(97, unit: null), isNull);
    });

    test('0 and 100.1 are out of range; 100 is in', () {
      expect(spo2PercentOrNull(0, unit: '%'), isNull);
      expect(spo2PercentOrNull(100.1, unit: '%'), isNull);
      expect(spo2PercentOrNull(100, unit: '%'), 100.0);
    });

    test('NaN and infinity are not percentages', () {
      expect(spo2PercentOrNull(double.nan, unit: '%'), isNull);
      expect(spo2PercentOrNull(double.infinity, unit: '%'), isNull);
      expect(spo2PercentOrNull(double.negativeInfinity, unit: '%'), isNull);
    });
  });

  group('summarizeSpo2Percent (batch-independent mean with count)', () {
    test('96, 98, 97 -> mean 97, count 3', () {
      final s = summarizeSpo2Percent([96, 98, 97]);
      expect(s, isNotNull);
      expect(s!.count, 3);
      expect(s.meanPercent, 97.0);
    });

    test('the upstream reference case: 90, 90, 100 -> 93.333...', () {
      final s = summarizeSpo2Percent([90, 90, 100]);
      expect(s, isNotNull);
      expect(s!.count, 3);
      expect(s.meanPercent, closeTo(93.33333333333333, 1e-10));
    });

    test('no samples -> no result', () {
      expect(summarizeSpo2Percent([]), isNull);
      expect(summarizeSpo2Percent(const Iterable.empty()), isNull);
    });

    test('an unvalidated sample throws, never silently skips', () {
      expect(() => summarizeSpo2Percent([97, 0]),
          throwsArgumentError);
      expect(() => summarizeSpo2Percent([97, 101]),
          throwsArgumentError);
      expect(() => summarizeSpo2Percent([97, double.nan]),
          throwsArgumentError);
    });

    test('batch size does not change the mean of the same samples', () {
      // The same ten samples, "delivered" in different groupings, must give
      // the same answer — the mean is over SAMPLES, not over batches.
      final all = <double>[97, 98, 96, 97, 99, 98, 97, 96, 98, 97];
      final whole = summarizeSpo2Percent(all)!;
      final split = [
        summarizeSpo2Percent(all.sublist(0, 3))!,
        summarizeSpo2Percent(all.sublist(3, 7))!,
        summarizeSpo2Percent(all.sublist(7))!,
      ];
      // Weighted reconstruction over the sub-batches must equal the whole —
      // this is the test that the naive mean-of-batch-means FAILS.
      final weighted = split.fold<double>(
              0, (acc, s) => acc + s.meanPercent * s.count) /
          all.length;
      expect(weighted, closeTo(whole.meanPercent, 1e-10));
      final naiveMeanOfBatchMeans =
          split.fold<double>(0, (acc, s) => acc + s.meanPercent) / 3;
      expect(
        naiveMeanOfBatchMeans == whole.meanPercent,
        isFalse,
        reason: 'the unweighted mean of batch means must NOT be the sample '
            'mean in general — equal only by luck here',
      );
    });

    test('the reference: two batches 90,90 / 100, unweighted is 95, '
        'sample mean is 93.333...', () {
      final a = summarizeSpo2Percent([90, 90])!;
      final b = summarizeSpo2Percent([100])!;
      expect(a.meanPercent, 90);
      expect(a.count, 2);
      expect(b.meanPercent, 100);
      expect(b.count, 1);
      // naive mean of batch means: 95 — WRONG, pinned as wrong.
      expect((a.meanPercent + b.meanPercent) / 2, 95);
      // the true sample mean over all three values.
      final true1 = summarizeSpo2Percent([90, 90, 100])!;
      expect(true1.meanPercent, closeTo(93.33333333333333, 1e-10));
      expect(true1.count, 3);
    });
  });

  group('eligibleOuraSpo2Percent (the release gate)', () {
    test('production gate constant is closed until hardware validation', () {
      expect(kOuraSpo2InterpretationVerified, isFalse,
          reason: 'flipping this is the documented release act — see '
              'guides/OURA_SPO2_ACCEPTANCE.md');
    });

    test('every gate closed alone is enough to refuse a valid value', () {
      const value = 97;
      expect(
        eligibleOuraSpo2Percent(
            value: value,
            unit: '%',
            deviceSelected: false,
            integrationEnabled: true,
            interpretationVerified: true,
            timeReferenceSuitable: true),
        isNull,
      );
      expect(
        eligibleOuraSpo2Percent(
            value: value,
            unit: '%',
            deviceSelected: true,
            integrationEnabled: false,
            interpretationVerified: true,
            timeReferenceSuitable: true),
        isNull,
      );
      expect(
        eligibleOuraSpo2Percent(
            value: value,
            unit: '%',
            deviceSelected: true,
            integrationEnabled: true,
            interpretationVerified: false,
            timeReferenceSuitable: true),
        isNull,
      );
      expect(
        eligibleOuraSpo2Percent(
            value: value,
            unit: '%',
            deviceSelected: true,
            integrationEnabled: true,
            interpretationVerified: true,
            timeReferenceSuitable: false),
        isNull,
      );
    });

    test('all gates open passes the percent contract through', () {
      expect(
        eligibleOuraSpo2Percent(
            value: 97,
            unit: '%',
            deviceSelected: true,
            integrationEnabled: true,
            interpretationVerified: true,
            timeReferenceSuitable: true),
        97.0,
      );
    });

    test('an open gate does not rescue an invalid value, and never scales', () {
      // Out of range, wrong unit, null — all refused.
      expect(
        eligibleOuraSpo2Percent(
            value: 101,
            unit: '%',
            deviceSelected: true,
            integrationEnabled: true,
            interpretationVerified: true,
            timeReferenceSuitable: true),
        isNull,
      );
      expect(
        eligibleOuraSpo2Percent(
            value: 97,
            unit: 'raw',
            deviceSelected: true,
            integrationEnabled: true,
            interpretationVerified: true,
            timeReferenceSuitable: true),
        isNull,
      );
      expect(
        eligibleOuraSpo2Percent(
            value: null,
            unit: '%',
            deviceSelected: true,
            integrationEnabled: true,
            interpretationVerified: true,
            timeReferenceSuitable: true),
        isNull,
      );
    });

    test('the adapter floor is 70 and documented as a layout bound', () {
      expect(kOuraSpo2AdapterFloor, 70);
    });
  });
}
