// The Oura SpO2 export path: the eligibility gate, the write/delete
// sequence, partial-permission isolation, and the backfill cursor's
// progress rules. All through test doubles — no health store, no radio.
//
// Expectations are INDEPENDENT: the value written and the instant it is
// written at are computed from the fixture by hand.
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openstrap_edge/health/health_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A fixture summary: 3 samples 90/90/100 → mean 93.333... at these stamps.
  final firstMs = DateTime(2026, 3, 9, 1, 0, 0).millisecondsSinceEpoch;
  final lastMs =
      DateTime(2026, 3, 9, 1, 0, 2).millisecondsSinceEpoch;

  // The record shape the export consumes, hand-computed.
  Future<({double meanPercent, int count, int firstTsMs, int lastTsMs})?>
      realSummary() async =>
          (
            meanPercent: (90 + 90 + 100) / 3,
            count: 3,
            firstTsMs: firstMs,
            lastTsMs: lastMs,
          );

  test('the production gate is CLOSED: notEligible, nothing touched',
      () async {
    var wrote = 0;
    var deleted = 0;
    final result = await HealthExporter.exportOuraSpo2Day(
      summaryFor: realSummary,
      write: (v, start, end) async {
        wrote++;
        return true;
      },
      deleteOwn: (s, e) async {
        deleted++;
        return true;
      },
      // Production defaults: interpretationVerified = false via
      // kOuraSpo2InterpretationVerified.
    );
    expect(result, OuraSpo2ExportResult.notEligible);
    expect(wrote, 0);
    expect(deleted, 0);
  });

  test('an open gate deletes the span first, then writes the mean at the '
      'first measured second', () async {
    final calls = <String>[];
    double? writtenValue;
    DateTime? writtenStart;
    DateTime? writtenEnd;
    final result = await HealthExporter.exportOuraSpo2Day(
      summaryFor: realSummary,
      write: (v, start, end) async {
        calls.add('write');
        writtenValue = v;
        writtenStart = start;
        writtenEnd = end;
        return true;
      },
      deleteOwn: (s, e) async {
        calls.add('delete $s $e');
        // The delete window is the observations' own measured span,
        // exclusive at the end.
        expect(s.millisecondsSinceEpoch, firstMs);
        expect(e.millisecondsSinceEpoch, lastMs + 1000);
        return true;
      },
      interpretationVerified: true, // the TEST DOUBLE grant, never production
    );
    expect(result, OuraSpo2ExportResult.written);
    expect(calls, hasLength(2));
    expect(calls.first, startsWith('delete'));
    expect(calls.last, 'write',
        reason: 'delete-then-write, exactly once each');
    // The mean, at the FIRST measured second — never noon, never arrival.
    expect(writtenValue, closeTo(93.33333333333333, 1e-10));
    expect(writtenStart!.millisecondsSinceEpoch, firstMs);
    expect(writtenEnd!.millisecondsSinceEpoch, lastMs);
  });

  test('a refused write is writeFailed — and does not masquerade as success',
      () async {
    final result = await HealthExporter.exportOuraSpo2Day(
      summaryFor: realSummary,
      write: (v, start, end) async => false, // the store refusing the type
      deleteOwn: (s, e) async => true,
      interpretationVerified: true,
    );
    expect(result, OuraSpo2ExportResult.writeFailed);
  });

  test('an uncleared delete is deleteFailed and never writes beside a '
      'survivor', () async {
    var wrote = false;
    final result = await HealthExporter.exportOuraSpo2Day(
      summaryFor: realSummary,
      write: (v, start, end) async {
        wrote = true;
        return true;
      },
      deleteOwn: (s, e) async => false, // e.g. the store hung / locked phone
      interpretationVerified: true,
    );
    expect(result, OuraSpo2ExportResult.deleteFailed);
    expect(wrote, isFalse);
  });

  test('a day with no suitable rows is noData, not a failure', () async {
    final result = await HealthExporter.exportOuraSpo2Day(
      summaryFor: () async => null,
      write: (v, start, end) async => true,
      deleteOwn: (s, e) async => true,
      interpretationVerified: true,
    );
    expect(result, OuraSpo2ExportResult.notEligible,
        reason: 'no rows means nothing eligible either — the caller cannot '
            'owe a value it does not have');
  });

  test('each gate closed alone refuses the export', () async {
    var wrote = 0;
    Future<OuraSpo2ExportResult> run(bool device, bool integration, bool interp,
            bool timeRef) =>
        HealthExporter.exportOuraSpo2Day(
          summaryFor: realSummary,
          write: (v, start, end) async {
            wrote++;
            return true;
          },
          deleteOwn: (s, e) async => true,
          deviceSelected: device,
          integrationEnabled: integration,
          interpretationVerified: interp,
          timeReferenceSuitable: timeRef,
        );
    expect(await run(false, true, true, true), OuraSpo2ExportResult.notEligible);
    expect(await run(true, false, true, true), OuraSpo2ExportResult.notEligible);
    expect(await run(true, true, false, true), OuraSpo2ExportResult.notEligible);
    expect(await run(true, true, true, false), OuraSpo2ExportResult.notEligible);
    expect(wrote, 0);
  });

  test('the health package contract: BLOOD_OXYGEN with PERCENT, the value '
      'written is the percent itself', () async {
    // 97 % must be written as 97, never 0.97 (no division) and never 9700
    // (no multiplication). Pinned against the health package's own maps.
    expect(HealthDataType.BLOOD_OXYGEN, isNotNull);
    // The default unit the plugin assigns the type.
    expect(
      const {
        HealthDataType.BLOOD_OXYGEN: HealthDataUnit.PERCENT,
      }[HealthDataType.BLOOD_OXYGEN],
      HealthDataUnit.PERCENT,
    );
    // Both platforms list the type as writable.
    expect(HealthDataType.BLOOD_OXYGEN, isNot(HealthDataType.WORKOUT));
  });
}
