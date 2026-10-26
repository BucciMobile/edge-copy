import 'dart:convert';

/// Sensor-specific calibration profile. Renamed from StepCalibrationProfile to 
/// avoid ambiguity with existing band-counter models.
class SensorCalibrationProfile {
  static const int kVersion = 100;
  
  final int version;
  final double meanMagnitude;
  final double variance;
  final List<double> meanGravity; // [x, y, z] derived from actual sensor data
  final int sampleCount;
  final DateTime createdAt;

  const SensorCalibrationProfile({
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

  factory SensorCalibrationProfile.fromJson(Map<String, dynamic> json) => SensorCalibrationProfile(
    version: json['v'] ?? kVersion,
    meanMagnitude: (json['mag'] as num).toDouble(),
    variance: (json['var'] as num).toDouble(),
    meanGravity: List<double>.from(json['grav']),
    sampleCount: json['cnt'] as int,
    createdAt: DateTime.parse(json['ts']),
  );
}
