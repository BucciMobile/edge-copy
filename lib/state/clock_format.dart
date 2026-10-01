// Clock format — a LOCAL display preference (system / 24-hour / 12-hour).
// Persisted on-device via SharedPreferences, mirroring UnitsController. It only
// changes how a time of day is DRAWN; nothing stored, exported or sent to the
// coach is formatted through it (those stay `HH:mm`, which is machine-readable).
//
// The formatters below are top-level and context-free on purpose: the app
// formats clock times in ~100 places, many of them pure functions with no
// BuildContext (notification bodies, labels computed in the read seam). They
// read the ACTIVE controller — the one [ClockFormatController.bootstrap] or
// [ClockFormatController.seed] built last — and fall back to the OS setting
// when there is none (a background isolate that never bootstrapped one).

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ClockFormat { system, h24, h12 }

extension ClockFormatLabel on ClockFormat {
  String get label => switch (this) {
        ClockFormat.system => 'System',
        ClockFormat.h24 => '24-hour',
        ClockFormat.h12 => '12-hour',
      };
}

class ClockFormatController extends ChangeNotifier {
  static const String _kClockFormat = 'clock_format'; // 'system'|'h24'|'h12'

  static ClockFormatController? _active;

  ClockFormat _format;
  ClockFormatController._(this._format) {
    _active = this;
  }

  factory ClockFormatController.seed(ClockFormat f) =>
      ClockFormatController._(f);

  static Future<ClockFormatController> bootstrap({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    // Timeout applied to preference loading BEFORE constructing the controller,
    // so a late SharedPreferences load cannot assign a controller to _active
    // after main.dart has already fallen back to the seeded system controller.
    final prefs = await SharedPreferences.getInstance().timeout(timeout);
    return ClockFormatController._(_parse(prefs.getString(_kClockFormat)));
  }

  /// An unknown stored value (an older build, a hand-edited pref) is "system".
  static ClockFormat _parse(String? s) => ClockFormat.values
      .firstWhere((f) => f.name == s, orElse: () => ClockFormat.system);

  ClockFormat get format => _format;

  /// Whether [format] resolves to 24-hour, given the OS's own answer.
  bool resolve24h(bool systemUse24h) => switch (_format) {
        ClockFormat.system => systemUse24h,
        ClockFormat.h24 => true,
        ClockFormat.h12 => false,
      };

  Future<void> setFormat(ClockFormat f) async {
    if (_format == f) return;
    _format = f;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kClockFormat, f.name);
  }

  /// Tapped through in place, like Units and Appearance.
  Future<void> cycle() => setFormat(
      ClockFormat.values[(_format.index + 1) % ClockFormat.values.length]);

  /// Tests only: forget the active controller so the next test starts from
  /// the OS setting again.
  @visibleForTesting
  static void debugReset() => _active = null;
}

/// Whether clock times render 24-hour right now: the user's choice, or the
/// OS's "use 24-hour format" when the choice is "system" (or no controller
/// exists in this isolate).
bool get use24HourClock {
  final system = _systemUse24h();
  return ClockFormatController._active?.resolve24h(system) ?? system;
}

/// The OS's answer, read through the binding when there is one — the same
/// dispatcher `MediaQuery` reads, so a formatted string and a time picker
/// cannot disagree. An isolate that never initialised a binding (a bare
/// background entry) reads the raw dispatcher instead.
bool _systemUse24h() {
  try {
    return WidgetsBinding.instance.platformDispatcher.alwaysUse24HourFormat;
  } catch (_) {
    return PlatformDispatcher.instance.alwaysUse24HourFormat;
  }
}

/// Hour + minute → "07:05" or "7:05 AM", per [use24HourClock].
String formatClock(int hour, int minute) {
  final mm = minute.toString().padLeft(2, '0');
  if (use24HourClock) return '${hour.toString().padLeft(2, '0')}:$mm';
  final h = hour % 12 == 0 ? 12 : hour % 12;
  return '$h:$mm ${hour < 12 ? 'AM' : 'PM'}';
}

/// The time of day of [d], as [formatClock].
String formatClockOf(DateTime d) => formatClock(d.hour, d.minute);

/// Local minutes past midnight, as [formatClock]. Wraps past 24 h.
String formatClockMinute(int minuteOfDay) {
  // Normalize negative values: -30 becomes 1410 (23:30), not -30.
  final m = ((minuteOfDay % 1440) + 1440) % 1440;
  return formatClock(m ~/ 60, m % 60);
}
