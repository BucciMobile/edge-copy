// A DISABLE_ALARM write that never reaches the band (write timeout, GATT
// error, link not ready) must not be reported as a cancel. The strap keeps
// its armed epoch and buzzes; if the app forgets the epoch on a failed write,
// nothing ever re-sends the disable.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';

BleEngine _engine(bool delivered, List<Uint8List> writes) {
  final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
  engine.debugInstallFakeLink(
    onWrite: (f) async {
      writes.add(f);
      return delivered;
    },
    listening: true,
  );
  return engine;
}

void main() {
  test('disableAlarm reports whether the write reached the band', () async {
    final failed = <Uint8List>[];
    expect(await _engine(false, failed).disableAlarm(), isFalse);
    expect(failed, isNotEmpty);

    final ok = <Uint8List>[];
    expect(await _engine(true, ok).disableAlarm(), isTrue);
  });

  test('every day off + failed disable keeps the armed epoch for a retry',
      () async {
    final writes = <Uint8List>[];
    final r = await armNextScheduledOccurrence(
      engine: _engine(false, writes),
      schedule: fillDefaultAlarmSchedule(const []),
      currentArmedEpoch: 1800000000,
    );
    expect(writes, isNotEmpty, reason: 'the disable was attempted');
    expect(r.disabled, isFalse,
        reason: 'the caller clears its armed epoch on disabled:true');
    expect(r.epoch, isNull);
  });

  test('every day off + delivered disable reports disabled', () async {
    final r = await armNextScheduledOccurrence(
      engine: _engine(true, []),
      schedule: fillDefaultAlarmSchedule(const []),
      currentArmedEpoch: 1800000000,
    );
    expect(r.disabled, isTrue);
  });
}
