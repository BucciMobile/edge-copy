import 'dart:convert';

/// Represents a sensor-based calibration profile for a specific activity category.
/// Version 100+ distinguishes this from legacy multiplicative band-calibration models.
class StepCalibrationProfile {
  static const int kVersion = 100;
  
  final int version;
  final double meanMagnitude;
  final double variance;
  final List<double> meanGravity; // [x, y, z]
  final int sampleCount;
  final DateTime createdAt;

  const StepCalibrationProfile({
    required this.version,
    required this.meanMagnitude,
    required this.variance,
    required this.meanGravity,
    required this.sampleCount,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'v': version, 'mag': meanMagnitude, 'var': variance,
    'grav': meanGravity, 'cnt': sampleCount, 'ts': createdAt.toIso8601String()
  };

  factory StepCalibrationProfile.fromJson(Map<String, dynamic> json) => StepCalibrationProfile(
    version: json['v'] ?? kVersion,
    meanMagnitude: (json['mag'] as num).toDouble(),
    variance: (json['var'] as num).toDouble(),
    meanGravity: List<double>.from(json['grav']),
    sampleCount: json['cnt'] as int,
    createdAt: DateTime.parse(json['ts']),
  );
}
