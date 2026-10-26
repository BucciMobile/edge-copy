import 'package:flutter_test/flutter_test.dart';
import '../lib/compute/sensor_step_engine.dart';
import '../lib/compute/sensor_calibration_profile.dart';

void main() {
  test('Engine estimates steps correctly for high-confidence signal', () {
    final profile = SensorCalibrationProfile(
      version: 100,
      meanMagnitude: 1.0,
      variance: 0.1,
      meanGravity: [0.0, 0.0, 1.0],
      sampleCount: 100,
      createdAt: DateTime.now(),
    );

    final magnitudes = [0.5, 1.5, 0.5, 1.5, 0.5, 1.5, 0.5];
    final steps = SensorStepEngine.estimateSteps(magnitudes, profile);
    expect(steps, 3);
  });
}
