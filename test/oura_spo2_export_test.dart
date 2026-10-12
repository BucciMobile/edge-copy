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
    final noContact = <String>[];
    final dirty = <({String date, String token})>[
      (date: '2026-03-12', token: 'a'),
      (date: '2026-03-11', token: 'b'), // in retry backoff: SKIPPED
      (date: '2026-03-10', token: 'c'),
      (date: '2026-03-09', token: 'd'), // fails
      (date: '2026-03-08', token: 'e'), // fails (2nd consecutive)
      (date: '2026-03-07', token: 'f'), // exports after the failures
    ];
    var globalFails = 0;
    await runOuraSpo2DirtyPass(
      dirtyDays: () async => dirty,
      retryDue: (d) async => d != '2026-03-11',
      processDay: (d) async {
        processed.add(d);
        if (d == '2026-03-09' || d == '2026-03-08') {
          return OuraSpo2DayOutcome.failed;
        }
        return OuraSpo2DayOutcome.exported;
      },
      clearDirty: (d, token) async => cleared.add('$d:$token'),
      noteDayFailures: (dates, {required bool flat}) async =>
          failedDays.addAll(dates.map((d) => flat ? '$d:flat' : d)),
      noteStoreSuccess: (d) async => succeededDays.add(d),
      noteNoContact: (d) async => noContact.add(d),
      noteGlobalFailure: (count) async => globalFails++,
    );
    // The backoff day was skipped entirely (not processed, not cleared).
    expect(processed, isNot(contains('2026-03-11')));
    // The pass continued past the two failures (03-07 succeeded), so
    // the failures were DAY-SCOPED and committed as day backoffs at the
    // end of the pass.
    expect(processed,
        ['2026-03-12', '2026-03-10', '2026-03-09', '2026-03-08', '2026-03-07']);
    expect(succeededDays, ['2026-03-12', '2026-03-10', '2026-03-07']);
    expect(failedDays, ['2026-03-09', '2026-03-08'],
        reason: 'day-scoped, NOT flat: the pass kept succeeding');
    expect(globalFails, 0, reason: 'no global stop: other days succeeded');
    expect(noContact, isEmpty);
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
      noteDayFailures: (dates, {required bool flat}) async =>
          fail('must not note failures on gateClosed'),
      noteStoreSuccess: (d) async =>
          fail('must not note store success on gateClosed'),
      noteNoContact: (d) async =>
          fail('must not note no-contact on gateClosed'),
      noteGlobalFailure: (count) async =>
          fail('must not note a global failure on gateClosed'),
    );
    expect(gateHit, isTrue);
    // Three consecutive failures stop the pass GLOBALLY: the 4th day is
    // never processed, ONE global marker is written (its own small
    // backoff), and NO per-day retry counters — a global cause must not
    // strand days behind day-backoff the moment it is fixed.
    final processed = <String>[];
    final dayBackoffs = <String>[];
    final flatFlags = <bool>[];
    var globalStops = 0;
    await runOuraSpo2DirtyPass(
      dirtyDays: () async => [
        (date: '2026-03-10', token: 'a'),
        (date: '2026-03-09', token: 'b'),
        (date: '2026-03-08', token: 'c'),
        (date: '2026-03-07', token: 'd'),
      ],
      retryDue: (d) async => true,
      processDay: (d) async {
        processed.add(d);
        return OuraSpo2DayOutcome.failed;
      },
      clearDirty: (d, token) async {},
      noteDayFailures: (dates, {required bool flat}) async {
        dayBackoffs.addAll(dates);
        flatFlags.add(flat);
      },
      noteStoreSuccess: (d) async => fail('no store success in this pass'),
      noteNoContact: (d) async => fail('no no-contact days in this pass'),
      noteGlobalFailure: (count) async => globalStops++,
      maxConsecutiveFailures: 3,
    );
    expect(processed, hasLength(3),
        reason: 'the 4th day was never attempted after 3 failures');
    expect(globalStops, 1, reason: 'exactly one global marker');
    expect(dayBackoffs, ['2026-03-10', '2026-03-09', '2026-03-08'],
        reason: 'the day counters ARE written on a global stop');
    expect(flatFlags, [true],
        reason: 'but FLAT: attempts stay 1 (a 5-minute backoff), so the '
            'same broken days cannot block older healthy days forever');
  });

  test('global hold: first stop holds nothing, growth and cap', () {
    const now = 1000000000000;
    // attempts 0 and 1 (the first stop) hold NOTHING.
    expect(ouraSpo2GlobalHold(attempts: 0, lastMs: now, nowMs: now),
        isFalse);
    expect(ouraSpo2GlobalHold(attempts: 1, lastMs: now, nowMs: now),
        isFalse);
    // attempts 3 -> 5 * 2 = 10 minutes (hand-computed).
    expect(
        ouraSpo2GlobalHold(
            attempts: 3, lastMs: now, nowMs: now + 9 * 60000),
        isTrue);
    expect(
        ouraSpo2GlobalHold(
            attempts: 3, lastMs: now, nowMs: now + 10 * 60000),
        isFalse);
    // attempts 100 -> 5 * 99 clamped to 60 minutes.
    expect(
        ouraSpo2GlobalHold(
            attempts: 100, lastMs: now, nowMs: now + 59 * 60000),
        isTrue);
    expect(
        ouraSpo2GlobalHold(
            attempts: 100, lastMs: now, nowMs: now + 60 * 60000),
        isFalse);
  });

  test('global hold: a clock that went backwards never holds', () {
    const now = 1000000000000;
    // The stamp sits 3 h in the FUTURE (clock went back): no hold.
    expect(
        ouraSpo2GlobalHold(
            attempts: 5, lastMs: now + 3 * 3600000, nowMs: now),
        isFalse);
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
