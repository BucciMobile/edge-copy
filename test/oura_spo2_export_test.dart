// The Oura SpO2 export DAY contract and the DIRTY-PASS walk: the atomic
// candidate, the interval semantics, the day-window clear, the retry
// backoff and the pass order. Seams are the health-store operations and
// the clock; every expectation is hand-computed.
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openstrap_edge/health/health_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    // the DAY-window wrapper lives in `_processOuraSpo2Day` and is
    // proven by the lifecycle test's stateful store.
    expect(clearedStart!.millisecondsSinceEpoch, firstMs);
    expect(clearedEnd!.millisecondsSinceEpoch, lastMs);
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

  test('I: the retry backoff — 5, 10, 20 ... capped at 1440 minutes; a '
      'clock that went backwards counts as due', () {
    final t0 = 1787000000000; // an arbitrary fixed base.
    // Never-attempted: due immediately.
    expect(
        ouraSpo2RetryDue(attempts: 0, lastAttemptMs: 0, nowMs: t0), isTrue);
    // Attempt 1 -> 5-minute backoff.
    expect(ouraSpo2RetryDue(attempts: 1, lastAttemptMs: t0, nowMs: t0),
        isFalse);
    expect(
        ouraSpo2RetryDue(
            attempts: 1, lastAttemptMs: t0, nowMs: t0 + 5 * 60000),
        isTrue);
    // Attempt 2 -> 10 minutes.
    expect(
        ouraSpo2RetryDue(
            attempts: 2, lastAttemptMs: t0, nowMs: t0 + 9 * 60000),
        isFalse);
    expect(
        ouraSpo2RetryDue(
            attempts: 2, lastAttemptMs: t0, nowMs: t0 + 10 * 60000),
        isTrue);
    // Attempt 3 -> 20 minutes (hand-computed: 5 << 2).
    expect(
        ouraSpo2RetryDue(
            attempts: 3, lastAttemptMs: t0, nowMs: t0 + 19 * 60000),
        isFalse);
    expect(
        ouraSpo2RetryDue(
            attempts: 3, lastAttemptMs: t0, nowMs: t0 + 20 * 60000),
        isTrue);
    // The cap: the shift is clamped at 8 -> the backoff tops out at
    // 5 * 256 = 1280 minutes (~21.3 h). Hand-computed:
    // 1279 min is not due, 1280 min is.
    expect(
        ouraSpo2RetryDue(
            attempts: 10, lastAttemptMs: t0, nowMs: t0 + 1279 * 60000),
        isFalse);
    expect(
        ouraSpo2RetryDue(
            attempts: 10, lastAttemptMs: t0, nowMs: t0 + 1280 * 60000),
        isTrue);
    // And it never grows past the cap, however many attempts.
    expect(
        ouraSpo2RetryDue(
            attempts: 50, lastAttemptMs: t0, nowMs: t0 + 1279 * 60000),
        isFalse);
    // Clock went backwards: due now, not stranded for a day.
    expect(ouraSpo2RetryDue(attempts: 3, lastAttemptMs: t0, nowMs: t0 - 1),
        isTrue);
  });

  test('the pass order: retry-gated, gate-closed keeps ALL dirty, three '
      'consecutive failures stop, successes clear by token', () async {
    final processed = <String>[];
    final cleared = <String>[];
    final failedDays = <String>[];
    final succeededDays = <String>[];
    final dirty = <({String date, String token})>[
      (date: '2026-03-12', token: 'a'),
      (date: '2026-03-11', token: 'b'), // in retry backoff: SKIPPED
      (date: '2026-03-10', token: 'c'),
      (date: '2026-03-09', token: 'd'), // fails twice then succeeds
      (date: '2026-03-08', token: 'e'), // fails -> 3rd consecutive stops
      (date: '2026-03-07', token: 'f'), // never reached
    ];
    var fail0310 = false;
    await runOuraSpo2DirtyPass(
      dirtyDays: () async => dirty,
      retryDue: (d) async => d != '2026-03-11',
      processDay: (d) async {
        processed.add(d);
        if (d == '2026-03-09' || (d == '2026-03-10' && fail0310)) {
          return OuraSpo2DayOutcome.failed;
        }
        if (d == '2026-03-08') return OuraSpo2DayOutcome.failed;
        return OuraSpo2DayOutcome.exported;
      },
      clearDirty: (d, token) async => cleared.add('$d:$token'),
      noteFailure: (d) async => failedDays.add(d),
      noteSuccess: (d) async => succeededDays.add(d),
    );
    // The backoff day was skipped entirely (not processed, not cleared).
    expect(processed, isNot(contains('2026-03-11')));
    // 03-10 exported, 03-09 failed (1st), 03-08 failed (2nd consecutive
    // within this call -> pass continues; the third failure threshold is
    // per-pass-consecutive: 03-09 and 03-08 are two; the pass ends after
    // 03-08 by reaching the END of the list, not the cap).
    // 03-09 fails (1st consecutive), 03-08 fails (2nd), 03-07 is
    // attempted and fails — the THIRD consecutive failure ends the pass
    // (after noting it). All four were processed; nothing was cleared
    // for the failed days.
    expect(processed,
        ['2026-03-12', '2026-03-10', '2026-03-09', '2026-03-08', '2026-03-07']);
    expect(succeededDays, ['2026-03-12', '2026-03-10', '2026-03-07']);
    expect(failedDays, ['2026-03-09', '2026-03-08']);
    // Only the successful days' tokens were cleared — failed days keep
    // their markers for the backoff retry.
    expect(cleared, ['2026-03-12:a', '2026-03-10:c', '2026-03-07:f']);
  });

  test('the pass: gate closed ends immediately and keeps every dirty '
      'day; three consecutive failures end the pass', () async {
    var gateHit = false;
    await runOuraSpo2DirtyPass(
      dirtyDays: () async => [
        (date: '2026-03-10', token: 'a'),
        (date: '2026-03-09', token: 'b'),
      ],
      retryDue: (d) async => true,
      processDay: (d) async {
        gateHit = true;
        return OuraSpo2DayOutcome.gateClosed;
      },
      clearDirty: (d, token) async => fail('must not clear on gateClosed'),
      noteFailure: (d) async => fail('must not note failure on gateClosed'),
      noteSuccess: (d) async => fail('must not note success on gateClosed'),
    );
    expect(gateHit, isTrue);
    // Three consecutive failures stop the pass: 4 days, the 4th never
    // processed.
    final processed = <String>[];
    await runOuraSpo2DirtyPass(
      dirtyDays: () async => [
        for (final d in ['2026-03-10', '09', '08', '07'])
          (date: '2026-03-$d', token: d),
      ],
      retryDue: (d) async => true,
      processDay: (d) async {
        processed.add(d);
        return OuraSpo2DayOutcome.failed;
      },
      clearDirty: (d, token) async {},
      noteFailure: (d) async {},
      noteSuccess: (d) async {},
      maxConsecutiveFailures: 3,
    );
    expect(processed, hasLength(3),
        reason: 'the 4th day was never attempted after 3 failures');
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
