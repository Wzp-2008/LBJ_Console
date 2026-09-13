/// Reports the Bluetooth Classic capabilities of the current platform.
///
/// Use [FlutterClassicBluetooth.getPlatformCapabilities] to obtain this.
/// Check capabilities before calling platform-specific features to avoid
/// [BtcUnsupportedException].
///
/// ```dart
/// final caps = await bluetooth.getPlatformCapabilities();
/// if (caps.canDiscoverDevices) {
///   await bluetooth.startDiscovery();
/// }
/// ```
///
/// {@category Models}
class BtcPlatformCapabilities {
  /// Whether the platform can programmatically enable Bluetooth.
  final bool canEnableBluetooth;

  /// Whether the platform can programmatically disable Bluetooth.
  final bool canDisableBluetooth;

  /// Whether the platform supports discovering nearby devices.
  final bool canDiscoverDevices;

  /// Whether the platform can retrieve previously paired devices.
  final bool canGetPairedDevices;

  /// Whether the platform can programmatically initiate pairing.
  final bool canBondDevices;

  /// Whether the platform can programmatically remove a bond.
  final bool canUnbondDevices;

  /// Whether the platform can create an RFCOMM server socket.
  final bool canCreateServer;

  /// Whether the platform can make the device discoverable to others.
  final bool canSetDiscoverable;

  /// Whether the platform supports multiple simultaneous connections.
  final bool supportsMultipleConnections;

  /// Whether the platform supports authenticated/encrypted RFCOMM connections.
  final bool supportsSecureConnection;

  /// Whether the platform supports unauthenticated RFCOMM connections.
  final bool supportsInsecureConnection;

  /// Whether the platform can read the live RSSI of an *open* connection.
  ///
  /// True only on **macOS** (via `IOBluetoothDevice`). No other platform
  /// exposes a public Bluetooth Classic API for connection RSSI. Discovery-time
  /// RSSI is reported separately on [BtcDevice.rssi] and is unaffected by this.
  final bool canReadConnectionRssi;

  /// Whether the platform requires MFi certification for accessories.
  ///
  /// True only on iOS, where Bluetooth Classic is limited to
  /// MFi-certified accessories via the ExternalAccessory framework.
  final bool requiresMfiCertification;

  /// Optional note describing platform-specific limitations.
  final String? platformNote;

  /// Creates a capability set; every flag defaults to `false` (unsupported).
  const BtcPlatformCapabilities({
    this.canEnableBluetooth = false,
    this.canDisableBluetooth = false,
    this.canDiscoverDevices = false,
    this.canGetPairedDevices = false,
    this.canBondDevices = false,
    this.canUnbondDevices = false,
    this.canCreateServer = false,
    this.canSetDiscoverable = false,
    this.supportsMultipleConnections = false,
    this.supportsSecureConnection = false,
    this.supportsInsecureConnection = false,
    this.canReadConnectionRssi = false,
    this.requiresMfiCertification = false,
    this.platformNote,
  });

  /// Creates [BtcPlatformCapabilities] from a platform channel map.
  factory BtcPlatformCapabilities.fromMap(Map<dynamic, dynamic> map) {
    return BtcPlatformCapabilities(
      canEnableBluetooth: map['canEnableBluetooth'] as bool? ?? false,
      canDisableBluetooth: map['canDisableBluetooth'] as bool? ?? false,
      canDiscoverDevices: map['canDiscoverDevices'] as bool? ?? false,
      canGetPairedDevices: map['canGetPairedDevices'] as bool? ?? false,
      canBondDevices: map['canBondDevices'] as bool? ?? false,
      canUnbondDevices: map['canUnbondDevices'] as bool? ?? false,
      canCreateServer: map['canCreateServer'] as bool? ?? false,
      canSetDiscoverable: map['canSetDiscoverable'] as bool? ?? false,
      supportsMultipleConnections:
          map['supportsMultipleConnections'] as bool? ?? false,
      supportsSecureConnection:
          map['supportsSecureConnection'] as bool? ?? false,
      supportsInsecureConnection:
          map['supportsInsecureConnection'] as bool? ?? false,
      canReadConnectionRssi: map['canReadConnectionRssi'] as bool? ?? false,
      requiresMfiCertification:
          map['requiresMfiCertification'] as bool? ?? false,
      platformNote: map['platformNote'] as String?,
    );
  }

  /// Converts to a map for platform channel communication.
  Map<String, dynamic> toMap() {
    return {
      'canEnableBluetooth': canEnableBluetooth,
      'canDisableBluetooth': canDisableBluetooth,
      'canDiscoverDevices': canDiscoverDevices,
      'canGetPairedDevices': canGetPairedDevices,
      'canBondDevices': canBondDevices,
      'canUnbondDevices': canUnbondDevices,
      'canCreateServer': canCreateServer,
      'canSetDiscoverable': canSetDiscoverable,
      'supportsMultipleConnections': supportsMultipleConnections,
      'supportsSecureConnection': supportsSecureConnection,
      'supportsInsecureConnection': supportsInsecureConnection,
      'canReadConnectionRssi': canReadConnectionRssi,
      'requiresMfiCertification': requiresMfiCertification,
      'platformNote': platformNote,
    };
  }

  @override
  String toString() =>
      'PlatformCapabilities(discover: $canDiscoverDevices, server: $canCreateServer, mfi: $requiresMfiCertification)';
}
