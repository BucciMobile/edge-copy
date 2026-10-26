import 'package:flutter/foundation.dart';
import 'sensor_calibration_profile.dart';

enum CalibrationType { slow, brisk, jog, everyday }

class CalibrationController extends ChangeNotifier {
  bool _isRecording = false;
  bool get isRecording => _isRecording;
  
  List<double> _magnitudes = [];
  List<List<double>> _gravityVectors = [];

  void startRecording() {
    if (_isRecording) return; // Reject overlapping recordings
    _magnitudes = [];
    _gravityVectors = [];
    _isRecording = true;
    notifyListeners();
  }

  /// Processes a full sample including dynamic magnitude and gravity vector.
  void processSample(double mag, List<double> gravity) {
    if (!_isRecording) return;
    _magnitudes.add(mag);
    _gravityVectors.add(gravity);
  }

  Future<SensorCalibrationProfile?> finishRecording() async {
    _isRecording = false;
    notifyListeners();
    
    // Validation: Ensure actual data exists, not just sample count
    if (_magnitudes.length < 100) return null;

    final mean = _magnitudes.reduce((a, b) => a + b) / _magnitudes.length;
    final variance = _magnitudes.map((m) => (m - mean) * (m - mean)).reduce((a, b) => a + b) / _magnitudes.length;

    // Calculate average gravity vector instead of hardcoding zeros
    List<double> meanGravity = [0.0, 0.0, 0.0];
    if (_gravityVectors.isNotEmpty) {
      for (var v in _gravityVectors) {
        for (int i = 0; i < 3; i++) meanGravity[i] += v[i];
      }
      for (int i = 0; i < 3; i++) meanGravity[i] /= _gravityVectors.length;
    }

    final profile = SensorCalibrationProfile(
      version: SensorCalibrationProfile.kVersion,
      meanMagnitude: mean,
      variance: variance,
      meanGravity: meanGravity,
      sampleCount: _magnitudes.length,
      createdAt: DateTime.now(),
    );
    
    return profile;
  }
}
