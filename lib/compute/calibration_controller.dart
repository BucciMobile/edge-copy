import 'package:flutter/foundation.dart';
import 'step_calibration_profile.dart';

enum CalibrationType { slow, brisk, jog, everyday }

class CalibrationController extends ChangeNotifier {
  bool _isRecording = false;
  bool get isRecording => _isRecording;
  
  List<double> _magnitudes = [];

  void startRecording() {
    _magnitudes = [];
    _isRecording = true;
    notifyListeners();
  }

  void processSample(double mag) {
    if (!_isRecording) return;
    _magnitudes.add(mag);
  }

  Future<StepCalibrationProfile?> finishRecording() async {
    _isRecording = false;
    if (_magnitudes.length < 100) return null;

    final mean = _magnitudes.reduce((a, b) => a + b) / _magnitudes.length;
    final variance = _magnitudes.map((m) => (m - mean) * (m - mean)).reduce((a, b) => a + b) / _magnitudes.length;

    final profile = StepCalibrationProfile(
      version: StepCalibrationProfile.kVersion,
      meanMagnitude: mean,
      variance: variance,
      meanGravity: [0.0, 0.0, 0.0], // To be populated with raw vector average
      sampleCount: _magnitudes.length,
      createdAt: DateTime.now(),
    );
    
    // Here: Integration with DB/Prefs (e.g. LocalRepository)
    return profile;
  }
}
