import 'package:flutter/foundation.dart';
import 'calibration_model.dart';

class CalibrationController extends ChangeNotifier {
  bool isRecording = false;
  CalibrationType? currentType;
  List<double> magnitudes = [];

  void startCalibration(CalibrationType type) {
    isRecording = true;
    currentType = type;
    magnitudes.clear();
    notifyListeners();
  }

  void processSample(double mag) {
    if (!isRecording) return;
    magnitudes.add(mag);
    if (magnitudes.length >= 100) { // Beispiel: 100 Samples als Kalibrierungs-Set
      finishCalibration();
    }
  }

  void finishCalibration() {
    isRecording = false;
    // Logik: Mean, Variance berechnen und CalibrationProfile erstellen
    final mean = magnitudes.reduce((a, b) => a + b) / magnitudes.length;
    final variance = magnitudes.map((m) => (m - mean) * (m - mean)).reduce((a, b) => a + b) / magnitudes.length;
    
    final profile = CalibrationProfile(
      meanMagnitude: mean,
      variance: variance,
      meanGravity: [0.0, 0.0, 0.0], // Vereinfacht für dieses Skelett
    );
    
    // In echten Controller schreiben...
    notifyListeners();
  }
}
