// The calibration's household reference on Android is the step sensor's own
// running total, read at the start and end of a routine after a flush. These
// pin the Dart side of that: the value passes through, a platform without it
// (iOS) answers null, and the settle wait only happens when a flush was made.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/health/phone_pedometer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(phoneStepsChannel, null));

  test('rawCount passes the sensor total through', () async {
    messenger.setMockMethodCallHandler(phoneStepsChannel, (c) async {
      if (c.method == 'rawCount') return 12345;
      return null;
    });
    expect(await PhonePedometer().rawCount(), 12345);
  });

  test('a platform without a running total answers null', () async {
    messenger.setMockMethodCallHandler(phoneStepsChannel, (c) async {
      throw MissingPluginException();
    });
    expect(await PhonePedometer().rawCount(), isNull);
    // And flushing there neither throws nor waits.
    final sw = Stopwatch()..start();
    await PhonePedometer().flushPending(settle: true);
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test('flush is asked of the platform', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(phoneStepsChannel, (c) async {
      calls.add(c.method);
      return false;
    });
    await PhonePedometer().flushPending();
    expect(calls, ['flush']);
  });
}
