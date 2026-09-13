# Local patches

Vendored from `flutter_classic_bluetooth` 1.3.0 (MIT; see `LICENSE`),
using the package source published at
`https://pub.dev/packages/flutter_classic_bluetooth/versions/1.3.0`.

- Exposes the remote 24-bit Bluetooth Class of Device as the nullable
  `BtcDevice.classOfDevice` field.
- Android reconstructs the value from public `BluetoothClass` device and
  service APIs for discovered and paired devices.
- Windows forwards `BLUETOOTH_DEVICE_INFO.ulClassofDevice`.
