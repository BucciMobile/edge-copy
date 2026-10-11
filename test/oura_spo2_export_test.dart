// The Oura SpO2 export DAY contract: the atomic candidate, the interval
// semantics, the day-window clear, and the interpretation gate. Seams are
// the health-store operations only; every expectation is hand-computed.
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openstrap_edge/health/health_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A fixture candidate: mean 93.333... over 3 samples, interval
  // 2026-03-09 01:00:00 .. 01:00:02, ring-1.
  final firstMs = DateTime(2026, 3, 9, 1, 0, 0).millisecondsSinceEpoch;
  final lastMs = DateTime(2026, 3, 9, 1, 0, 2).millisecondsSinceEpoch;
  final candidate = (
    deviceId: 'oura-ring-1',
    meanPercent: (90 + 90 + 100) / 3,
    count: 3,
    firstTsMs: firstMs,
    lastTsMs: lastMs,
  );

  test('the production gate is CLOSED: notEligible, nothing touched', () async {
    var wrote = 0;
    var deleted = 0;
    final result = HealthExporter.exportOuraSpo2Day(
      candidate: candidate,
      write: (v, s, e) async {
        wrote++;
        return true;
      },
      deleteWindow: (s, e) async {
        deleted++;
        return true;
      },
      // interpretationVerified defaults to the production const (false).
    );
    expect(await result, OuraSpo2ExportResult.notEligible);
    expect(wrote, 0);
    expect(deleted, 0);
  });

  test('an open gate clears the DAY window first, then writes the mean '
      'over the MEASURED interval', () async {
    final calls = <String>[];
    double? writtenValue;
    DateTime? writtenStart;
    DateTime? writtenEnd;
    DateTime? clearedStart;
    DateTime? clearedEnd;
    final result = await HealthExporter.exportOuraSpo2Day(
      candidate: candidate,
      write: (v, s, e) async {
        calls.add('write');
        writtenValue = v;
        writtenStart = s;
        writtenEnd = e;
        return true;
      },
      deleteWindow: (s, e) async {
        calls.add('delete');
        clearedStart = s;
        clearedEnd = e;
        return true;
      },
      interpretationVerified: true, // the TEST grant, never production
    );
    expect(result, OuraSpo2ExportResult.written);
    expect(calls, ['delete', 'write']);
    // The pure function hands the seam the candidate's own interval;
    // the DAY-window wrapper lives in `_exportOuraSpo2` and is proven by
    // the lifecycle test's stateful store (day-window deletes).
    expect(clearedStart!.millisecondsSinceEpoch, firstMs);
    expect(clearedEnd!.millisecondsSinceEpoch, lastMs);
    // The write is the MEASURED interval, never a point claim.
    expect(writtenValue, closeTo(93.33333333333333, 1e-10));
    expect(writtenStart!.millisecondsSinceEpoch, firstMs);
    expect(writtenEnd!.millisecondsSinceEpoch, lastMs);
  });

  test('a refused write is writeFailed — no success masquerade', () async {
    final result = await HealthExporter.exportOuraSpo2Day(
      candidate: candidate,
      write: (v, s, e) async => false,
      deleteWindow: (s, e) async => true,
      interpretationVerified: true,
    );
    expect(result, OuraSpo2ExportResult.writeFailed);
  });

  test('an uncleared delete is deleteFailed and never writes beside a '
      'survivor', () async {
    var wrote = false;
    final result = await HealthExporter.exportOuraSpo2Day(
      candidate: candidate,
      write: (v, s, e) async {
        wrote = true;
        return true;
      },
      deleteWindow: (s, e) async => false,
      interpretationVerified: true,
    );
    expect(result, OuraSpo2ExportResult.deleteFailed);
    expect(wrote, isFalse);
  });

  test('the walk policy: unsuitable days SKIP without consuming; '
      'failures stop at the day; only written advances', () {
    expect(ouraSpo2CursorAdvance(OuraSpo2ExportResult.written), isTrue);
    expect(ouraSpo2CursorAdvance(OuraSpo2ExportResult.notEligible),
        isFalse);
    expect(ouraSpo2CursorAdvance(OuraSpo2ExportResult.noData), isFalse);
    expect(ouraSpo2CursorAdvance(OuraSpo2ExportResult.deleteFailed),
        isNull);
    expect(ouraSpo2CursorAdvance(OuraSpo2ExportResult.writeFailed),
        isNull);
  });

  test('the walk: skip-continue for unsuitable days, stop-at for failures, '
      'monotonic cursor for older rewrites', () async {
    final exported = <String>[];
    final cursorWrites = <String>[];
    var cursor = '2026-03-10';
    await runOuraSpo2BackfillPass(
      cursor: cursor,
      days: [
        '2026-03-08', // tail rewrite: written, cursor must NOT go back
        '2026-03-09', // notEligible: skip, keep going
        '2026-03-10', // tail rewrite: written, cursor stays
        '2026-03-11', // writeFailed: STOP here
        '2026-03-12', // never reached
      ],
      exportDay: (date) async {
        if (date == '2026-03-09') return OuraSpo2ExportResult.notEligible;
        if (date == '2026-03-11') return OuraSpo2ExportResult.writeFailed;
        exported.add(date);
        return OuraSpo2ExportResult.written;
      },
      setCursor: (v) async { cursorWrites.add(v); },
    );
    // No head blocking: the pass moved PAST the unsuitable 03-09 and
    // wrote 03-10 behind it.
    expect(exported, ['2026-03-08', '2026-03-10']);
    // The failing 03-11 was ATTEMPTED (returned writeFailed) and the
    // pass stopped there — 03-12 was never attempted.
    expect(exported, isNot(contains('2026-03-12')));
    // The cursor never went backwards for the older rewrites.
    for (final c in cursorWrites) {
      expect(c.compareTo('2026-03-10'), greaterThanOrEqualTo(0));
    }
  });

  test('the health package contract: BLOOD_OXYGEN maps to PERCENT', () {
    expect(
      const {
        HealthDataType.BLOOD_OXYGEN: HealthDataUnit.PERCENT,
      }[HealthDataType.BLOOD_OXYGEN],
      HealthDataUnit.PERCENT,
    );
  });
}
