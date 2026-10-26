import 'dart:math';
import 'sensor_calibration_profile.dart';

/// Provides a confidence-based step estimation layer using WHOOP Gen5 raw sensor vectors.
/// Only active if deviceFamily is 'gen5' and profile is calibrated.
class SensorStepEngine {
  static const double kConfidenceThreshold = 0.85;

  static int? estimateSteps(List<double> magnitudes, SensorCalibrationProfile profile) {
    if (magnitudes.isEmpty) return null;

    final rms = sqrt(magnitudes.map((m) => m * m).reduce((a, b) => a + b) / magnitudes.length);
    final distance = (rms - profile.meanMagnitude).abs() / max(0.1, profile.variance);
    final confidence = exp(-distance); 
    
    if (confidence >= kConfidenceThreshold) {
      int steps = 0;
      for (int i = 1; i < magnitudes.length - 1; i++) {
        if (magnitudes[i] > profile.meanMagnitude && 
            magnitudes[i] > magnitudes[i-1] && 
            magnitudes[i] > magnitudes[i+1]) {
          steps++;
        }
      }
      return steps;
    }
    return null;
  }
}
