import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The Siri "Enable tomorrow's alarm" intent picks the weekday in Swift, where
// no Dart test can run it. Asked after midnight, "tomorrow" is the morning
// still ahead (today's weekday); taking the next calendar date left that
// morning's slot off and turned on the one after it.
void main() {
  test('EnableTomorrowAlarmIntent uses a noon cut-off before rolling a day',
      () {
    final swift = File('ios/OpenStrapIntents.swift').readAsStringSync();
    final start = swift.indexOf('struct EnableTomorrowAlarmIntent');
    expect(start, isNonNegative);
    final end = swift.indexOf('// MARK:', start);
    final body = swift.substring(start, end < 0 ? swift.length : end);

    expect(body, contains('cal.component(.hour, from: now) < 12'));
    expect(body, contains('cal.component(.weekday, from: target)'));
    expect(body, isNot(contains('cal.component(.weekday, from: tomorrow)')));
  });
}
