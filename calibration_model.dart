// Calibration types for step estimation.
enum CalibrationType { slow, brisk, jog, everyday }

/// Profile storing calibrated features from the accelerometer vector (gravityG & dynamicAccelerationG).
class CalibrationProfile {
  final double meanMagnitude;
  final double variance;
  final List<double> meanGravity; // [x, y, z]

  const CalibrationProfile({
    required this.meanMagnitude,
    required this.variance,
    required this.meanGravity,
  });

  Map<String, dynamic> toJson() => {
        'meanMagnitude': meanMagnitude,
        'variance': variance,
        'meanGravity': meanGravity,
      };

  factory CalibrationProfile.fromJson(Map<String, dynamic> json) => CalibrationProfile(
        meanMagnitude: json['meanMagnitude'],
        variance: json['variance'],
        meanGravity: List<double>.from(json['meanGravity']),
      );
}
