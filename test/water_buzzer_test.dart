// Tests for WaterBuzzer's lateness check. Dart timers run on the monotonic
// clock, which stalls while the device sleeps, so a timer armed for a 21:00
// slot can expire hours later in wall-clock terms. A strap buzz at 01:30 for a
// reminder the notification already delivered is worse than no buzz.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/water_buzzer.dart';

class _Harness {
  int buzzes = 0;
  late DateTime wall;
  late WaterBuzzer buzzer;

  _Harness(this.wall) {
    buzzer = WaterBuzzer(
      buzz: () async => buzzes++,
      isConnected: () => true,
      now: () => wall,
    );
  }
}

void main() {
  // 20:59:59 with a 21:00 slot arms a 1 s timer.
  final armedAt = DateTime(2026, 10, 22, 20, 59, 59);
  const slot = 21 * 60;

  test('buzzes when the timer fires at the slot', () async {
    final h = _Harness(armedAt);
    h.buzzer.configure(enabled: true, slotMinutes: [slot]);
    h.wall = DateTime(2026, 10, 22, 21);

    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(h.buzzes, 1);
    h.buzzer.dispose();
  });

  test('does not buzz when the timer fires hours late', () async {
    final h = _Harness(armedAt);
    h.buzzer.configure(enabled: true, slotMinutes: [slot]);
    // The phone slept: wall-clock reached 01:30 before the timer expired.
    h.wall = DateTime(2026, 10, 23, 1, 30);

    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(h.buzzes, 0);
    h.buzzer.dispose();
  });
}
