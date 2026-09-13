import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BtcDevice preserves Class of Device through map round-trip', () {
    const device = BtcDevice(
      address: 'AA:BB:CC:DD:EE:FF',
      name: 'LBJ Updater',
      classOfDevice: 0x801FFC,
    );

    final restored = BtcDevice.fromMap(device.toMap());

    expect(restored.classOfDevice, 0x801FFC);
  });

  test('BtcDevice merge keeps a previously discovered Class of Device', () {
    const first = BtcDevice(
      address: 'AA:BB:CC:DD:EE:FF',
      classOfDevice: 0x801FFC,
    );
    const update = BtcDevice(address: 'AA:BB:CC:DD:EE:FF', rssi: -40);

    expect(first.mergedWith(update).classOfDevice, 0x801FFC);
  });
}
