// DEVICE-ONLY integration test: the decisive evidence for the iOS
// percent-unit scale (A2 of the round-10 audit).
//
// HealthKit has no simulator support for HealthKit writes, so this runs
// ONLY on a real iPhone and is NOT part of the normal suite. See
// docs/oura_spo2_device_check.md for the full procedure.
//
// WHAT IT PROVES: the pinned health plugin (12.2.1) writes
// BLOOD_OXYGEN through `HKQuantity(unit: HKUnit.percent(), ...)` with
// NO scaling, and HKUnit.percent() is a FRACTION (0.0-1.0). Edge's
// model is percent (97.0 == 97%), so `ouraSpo2PluginWrite` divides by
// 100 on Apple. This round trip writes 97%, reads the RAW plugin value
// back, and expects 0.97 — the read uses the same HKUnit.percent(), so
// a raw 97.0 would mean the write path is wrong and A1 must be
// revisited.
//
// The decisive check is VISUAL: after this test, the Apple Health app
// must show "97%" under Vitalwerte > Blutsauerstoff for the marked
// window — not "9700%". The test deletes ONLY its own sample.
import 'package:health/health.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/health/health_export.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BLOOD_OXYGEN round trip: 97 percent on the device',
      (tester) async {
    final health = Health();
    await health.configure();
    final ok = await health.requestAuthorization(
      [HealthDataType.BLOOD_OXYGEN],
      permissions: [HealthDataAccess.READ_WRITE],
    );
    expect(ok, isTrue, reason: 'grant SpO2 read/write in the sheet');

    // A far-past, unambiguous window so the app's real data is never
    // near it.
    final start = DateTime(2020, 1, 2, 3, 0, 0);
    final end = start.add(const Duration(seconds: 60));
    final w = ouraSpo2PluginWrite(97, start, end, apple: true)!;
    final wrote = await health.writeHealthData(
      value: w.value,
      type: w.type,
      unit: w.unit,
      startTime: w.start,
      endTime: w.end,
    );
    expect(wrote, isTrue);

    final back = await health.getHealthDataFromTypes(
      types: [HealthDataType.BLOOD_OXYGEN],
      startTime: start.subtract(const Duration(minutes: 1)),
      endTime: end.add(const Duration(minutes: 1)),
    );
    final raw = back
        .map((p) => (p.value as NumericHealthValue).numericValue)
        .toList();
    // ignore: avoid_print
    print('RAW READ-BACK: $raw  (window $start .. $end)');
    // The plugin reads with HKUnit.percent(): a fraction. 0.97 means the
    // stored sample is 97%. 97.0 would mean it is stored as 9700%.
    expect(raw, isNotEmpty);
    expect(raw.single, closeTo(0.97, 1e-6));

    // Clean up ONLY this test's own sample.
    await health.delete(
      type: HealthDataType.BLOOD_OXYGEN,
      startTime: start,
      endTime: end,
    );
  });
}
