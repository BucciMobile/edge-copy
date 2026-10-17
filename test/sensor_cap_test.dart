// The two-sensor pairing cap is decided from the paired `device` rows, and
// the picker asks it before every pair rather than once on the way in.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart'
    show kMaxConcurrentSecondaryLinks;
import 'package:openstrap_edge/data/db.dart' show LocalDb;
import 'package:openstrap_edge/ui2/profile/devices.dart' show sensorCapReached;

List<Map<String, Object?>> _rows(int secondaries, {bool band = true}) => [
      if (band) {'id': LocalDb.kPrimaryDeviceId},
      for (var i = 0; i < secondaries; i++) {'id': 'hrs:$i'},
    ];

void main() {
  test('the primary band never counts against the cap', () {
    expect(sensorCapReached(_rows(kMaxConcurrentSecondaryLinks - 1)), isFalse);
    expect(
        sensorCapReached(_rows(kMaxConcurrentSecondaryLinks - 1, band: false)),
        isFalse);
  });

  test('reaching the cap refuses the next sensor', () {
    expect(sensorCapReached(_rows(kMaxConcurrentSecondaryLinks)), isTrue);
    expect(sensorCapReached(_rows(kMaxConcurrentSecondaryLinks + 1)), isTrue);
  });

  test('pairing a sensor that already has its row again is not an addition',
      () {
    final rows = _rows(kMaxConcurrentSecondaryLinks);
    expect(sensorCapReached(rows, repairingId: 'hrs:0'), isFalse);
    expect(sensorCapReached(rows, repairingId: 'hrs:new'), isTrue);
    // The band's own id is never a sensor re-pair.
    expect(sensorCapReached(rows, repairingId: LocalDb.kPrimaryDeviceId),
        isTrue);
  });
}
