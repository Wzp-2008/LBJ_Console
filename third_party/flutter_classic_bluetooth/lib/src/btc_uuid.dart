/// Well-known Bluetooth Classic service UUIDs.
///
/// Use these instead of pasting raw UUID strings. The vast majority of serial
/// Bluetooth devices (HC-05, HC-06, ESP32, ESP8266, Arduino modules, and most
/// embedded RFCOMM peripherals) speak the Serial Port Profile ([spp]), which is
/// the default UUID used by [FlutterClassicBluetooth.connect] and
/// [FlutterClassicBluetooth.startServer].
///
/// {@category Core}
abstract final class BtcUuid {
  /// Serial Port Profile (SPP): the standard RFCOMM serial UUID
  /// (`00001101-0000-1000-8000-00805F9B34FB`).
  ///
  /// This is the UUID used by HC-05/HC-06 modules, ESP32/ESP8266, Arduino
  /// Bluetooth shields, and the overwhelming majority of serial Bluetooth
  /// devices. It is the default for connecting and for hosting a server.
  static const String spp = '00001101-0000-1000-8000-00805F9B34FB';
}
