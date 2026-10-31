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

  group('the routine reference', () {
    Future<int?> never() async => fail('must not be read');

    test('android uses the difference of two flushed totals', () async {
      expect(
          await routinePhoneReference(
            runningTotalPlatform: true,
            startTotal: 1000,
            endTotal: () async => 1240,
            interval: never,
          ),
          240);
    });

    test('android without a starting total refuses, never prorates', () async {
      var prorated = false;
      expect(
          await routinePhoneReference(
            runningTotalPlatform: true,
            startTotal: null,
            endTotal: () async => 1240,
            interval: () async {
              prorated = true;
              return 99;
            },
          ),
          isNull);
      expect(prorated, isFalse);
    });

    test('android without an ending total refuses', () async {
      expect(
          await routinePhoneReference(
            runningTotalPlatform: true,
            startTotal: 1000,
            endTotal: () async => null,
            interval: never,
          ),
          isNull);
    });

    test('elsewhere the exact interval query is used', () async {
      expect(
          await routinePhoneReference(
            runningTotalPlatform: false,
            startTotal: null,
            endTotal: never,
            interval: () async => 57,
          ),
          57);
    });
  });

  test('a refused flush is reported and not waited out', () async {
    messenger.setMockMethodCallHandler(phoneStepsChannel, (c) async {
      if (c.method == 'flush') return false;
      if (c.method == 'rawCount') return 5000;
      return null;
    });
    final sw = Stopwatch()..start();
    expect(await PhonePedometer().flushPending(settle: true), isFalse);
    expect(sw.elapsedMilliseconds, lessThan(1000));
    expect(await PhonePedometer().flushedTotal(), isNull);
  });
}
