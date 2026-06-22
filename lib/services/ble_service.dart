import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_blue_plus_windows/flutter_blue_plus_windows.dart';
import 'package:lbjconsole/models/train_record.dart';
import 'package:lbjconsole/services/database_service.dart';
import 'package:lbjconsole/services/rtl_tcp_service.dart';

class BLEService {
  static final BLEService _instance = BLEService._internal();

  factory BLEService() => _instance;

  BLEService._internal() {
    _rtlTcpService = RtlTcpService();
  }

  late final RtlTcpService _rtlTcpService;

  RtlTcpService? get rtlTcpService => _rtlTcpService;

  static const String TAG = "LBJ_BT_FLUTTER";
  static final Guid serviceUuid = Guid("0000ffe0-0000-1000-8000-00805f9b34fb");
  static final Guid charUuid = Guid("0000ffe1-0000-1000-8000-00805f9b34fb");

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _characteristic;
  StreamSubscription<List<int>>? _valueSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;

  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  final StreamController<TrainRecord> _dataController =
      StreamController<TrainRecord>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  final StreamController<DateTime?> _lastReceivedTimeController =
      StreamController<DateTime?>.broadcast();

  Stream<String> get statusStream => _statusController.stream;

  Stream<TrainRecord> get dataStream => _dataController.stream;

  Stream<bool> get connectionStream => _connectionController.stream;

  Stream<DateTime?> get lastReceivedTimeStream =>
      _lastReceivedTimeController.stream;

  String _deviceStatus = "未连接";
  String? _lastKnownDeviceAddress;
  String? _lastKnownDeviceDisplayName;
  String _targetDeviceName = "LBJReceiver";
  DateTime? _lastReceivedTime;

  bool _isConnecting = false;
  bool _isManualDisconnect = false;
  bool _isAutoConnectBlocked = false;

  Timer? _heartbeatTimer;
  final StringBuffer _dataBuffer = StringBuffer();

  void initialize() {
    _loadSettings();
    FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        ensureConnection();
      } else {
        _updateConnectionState(false, "蓝牙已关闭");
        stopScan();
      }
    });
    _startHeartbeat();
    // Check immediately — don't wait for adapter state change event
    FlutterBluePlus.adapterState.first.then((state) {
      if (state == BluetoothAdapterState.on) {
        ensureConnection();
      }
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 7), (timer) {
      ensureConnection();
    });
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await DatabaseService.instance.getAllSettings();
      if (settings != null) {
        _targetDeviceName = settings['deviceName'] ?? 'LBJReceiver';
        _lastKnownDeviceAddress = settings['specifiedDeviceAddress'] as String?;
      }
    } catch (e) {}
  }

  void ensureConnection() {
    if (isConnected || _isConnecting) {
      return;
    }
    _tryReconnectDirectly();
  }

  Future<void> _tryReconnectDirectly() async {
    _isConnecting = true;
    _statusController.add("正在重连...");

    try {
      final connected = FlutterBluePlus.connectedDevices;

      // First: try match by last known address
      BluetoothDevice? target;
      if (_lastKnownDeviceAddress != null) {
        target = connected.cast<BluetoothDevice?>().firstWhere(
          (d) => d!.remoteId.str == _lastKnownDeviceAddress,
          orElse: () => null,
        );
      }

      // Second: try match by device name (OS may have maintained the connection but with a different handle)
      if (target == null) {
        target = connected.cast<BluetoothDevice?>().firstWhere(
          (d) => d!.platformName.toLowerCase() == _targetDeviceName.toLowerCase(),
          orElse: () => null,
        );
      }

      if (target != null) {
        await connect(target);
      } else {
        startScan();
        _isConnecting = false;
      }
    } catch (e) {
      startScan();
      _isConnecting = false;
    }
  }

  Future<void> startScan({
    String? targetName,
    Duration? timeout,
    Function(List<BluetoothDevice>)? onScanResults,
  }) async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }

    _targetDeviceName = targetName ?? _targetDeviceName;
    _statusController.add("正在扫描...");

    _scanResultsSubscription?.cancel();
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
      final allFoundDevices = results.map((r) => r.device).toList();

      final filteredDevices = allFoundDevices.where((device) {
        if (_targetDeviceName.isEmpty) return true;
        return device.platformName.toLowerCase() ==
            _targetDeviceName.toLowerCase();
      }).toList();

      onScanResults?.call(filteredDevices);

      if (isConnected ||
          _isConnecting ||
          _isManualDisconnect ||
          _isAutoConnectBlocked) {
        return;
      }

      for (var device in allFoundDevices) {
        if (_shouldAutoConnectTo(device)) {
          stopScan();
          connect(device);
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: timeout,
        withServices: [Guid.fromString("0000FFE0-0000-1000-8000-00805F9B34FB")],
      );
    } catch (e) {
      _statusController.add("扫描失败");
    }
  }

  bool _shouldAutoConnectTo(BluetoothDevice device) {
    final deviceName = device.platformName;
    final deviceAddress = device.remoteId.str;

    if (_targetDeviceName.isNotEmpty &&
        deviceName.toLowerCase() == _targetDeviceName.toLowerCase()) {
      return true;
    }
    if (_lastKnownDeviceAddress != null &&
        _lastKnownDeviceAddress == deviceAddress) {
      return true;
    }

    return false;
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _scanResultsSubscription?.cancel();
  }

  Future<void> connect(BluetoothDevice device) async {
    if (isConnected) return;

    _isConnecting = true;
    _isManualDisconnect = false;
    _statusController.add("正在连接: ${device.platformName}");

    try {
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });

      // If already connected at OS level, skip connect() and go straight to service discovery
      final systemConnected = FlutterBluePlus.connectedDevices;
      final alreadyConnected = systemConnected.any((d) => d.remoteId == device.remoteId);

      if (!alreadyConnected) {
        await device.connect(timeout: const Duration(seconds: 15));
      } else if (Platform.isWindows) {
        // WinBle needs a short settle time before GATT discovery on existing links.
        await Future.delayed(const Duration(milliseconds: 400));
      }
      await _onConnected(device);
    } catch (e) {
      _onDisconnected();
    }
  }

  Future<void> _onConnected(BluetoothDevice device) async {
    _rememberDeviceIdentity(device);
    await _discoverServicesAndSetupNotifications(device);
  }

  void _rememberDeviceIdentity(BluetoothDevice device) {
    final address = device.remoteId.str;
    if (address.isNotEmpty) {
      _lastKnownDeviceAddress = address;
      DatabaseService.instance.setSetting('specifiedDeviceAddress', address);
    }
    final name = device.platformName.trim();
    if (name.isNotEmpty) {
      _lastKnownDeviceDisplayName = name;
    }
  }

  Future<List<BluetoothService>> _discoverServicesWithRetry(
    BluetoothDevice device, {
    int attempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        if (attempt > 0) {
          await Future.delayed(Duration(milliseconds: 350 * attempt));
        }
        return await device.discoverServices();
      } catch (e) {
        lastError = e;
        if (!Platform.isWindows || attempt >= attempts - 1) {
          rethrow;
        }
      }
    }
    throw lastError ?? Exception('discoverServices failed');
  }

  Future<void> _writeTimeSyncToWritableCharacteristics(
    List<BluetoothService> services,
  ) async {
    final now = DateTime.now();
    final formatted =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final payload = utf8.encode('TIME:$formatted');

    for (final service in services) {
      for (final c in service.characteristics) {
        try {
          bool write =
              c.properties.write || c.properties.writeWithoutResponse;
          if (Platform.isWindows) {
            final prop = (c as BluetoothCharacteristicWindows).propertiesWinBle;
            write = prop.write == true || prop.writeWithoutResponse == true;
          }
          if (write) {
            await c.write(payload);
          }
        } catch (_) {}
      }
    }
  }

  Future<void> _discoverServicesAndSetupNotifications(
    BluetoothDevice device,
  ) async {
    try {
      final services = await _discoverServicesWithRetry(device);
      await _writeTimeSyncToWritableCharacteristics(services);

      for (var service in services) {
        if (service.uuid == serviceUuid) {
          for (var char in service.characteristics) {
            if (char.uuid == charUuid) {
              _characteristic = char;
              _connectedDevice = device;
              await device.requestMtu(512);
              await char.setNotifyValue(true);
              _valueSubscription = char.lastValueStream.listen(_onDataReceived);

              _updateConnectionState(true, "已连接");
              _isConnecting = false;
              return;
            }
          }
        }
      }
      throw Exception('LBJ GATT service not found');
    } catch (e) {
      _isConnecting = false;
      await _valueSubscription?.cancel();
      _valueSubscription = null;
      _characteristic = null;
      try {
        await device.disconnect();
      } catch (_) {}
      _onDisconnected(attemptReconnect: true);
    }
  }

  void _onDisconnected({bool attemptReconnect = true}) {
    final wasConnected = isConnected;
    _updateConnectionState(false, "连接已断开");
    _connectionStateSubscription?.cancel();

    if ((wasConnected || attemptReconnect) && !_isManualDisconnect) {
      ensureConnection();
    }
    _isConnecting = false;
  }

  Future<void> connectManually(BluetoothDevice device) async {
    _isManualDisconnect = false;
    _isAutoConnectBlocked = false;
    stopScan();
    await connect(device);
  }

  Future<void> disconnect() async {
    _isManualDisconnect = true;
    stopScan();

    await _connectionStateSubscription?.cancel();
    await _valueSubscription?.cancel();
    _valueSubscription = null;

    final device = _connectedDevice;
    _characteristic = null;
    _connectedDevice = null;

    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    _onDisconnected(attemptReconnect: false);
  }

  void _onDataReceived(List<int> value) {
    if (value.isEmpty) return;
    try {
      final data = utf8.decode(value);
      _dataBuffer.write(data);
      _processDataBuffer();
    } catch (e) {}
  }

  void _processDataBuffer() {
    String bufferContent = _dataBuffer.toString();
    if (bufferContent.isEmpty) return;

    int firstBrace = bufferContent.indexOf('{');
    if (firstBrace == -1) {
      _dataBuffer.clear();
      return;
    }

    bufferContent = bufferContent.substring(firstBrace);
    int braceCount = 0;
    int lastValidJsonEnd = -1;

    for (int i = 0; i < bufferContent.length; i++) {
      if (bufferContent[i] == '{') {
        braceCount++;
      } else if (bufferContent[i] == '}') {
        braceCount--;
      }
      if (braceCount == 0 && i > 0) {
        lastValidJsonEnd = i;
        String jsonToParse = bufferContent.substring(0, lastValidJsonEnd + 1);
        _parseAndNotify(jsonToParse);
        bufferContent = bufferContent.substring(lastValidJsonEnd + 1);
        i = -1;
        firstBrace = bufferContent.indexOf('{');
        if (firstBrace != -1) {
          bufferContent = bufferContent.substring(firstBrace);
        } else {
          break;
        }
      }
    }
    _dataBuffer.clear();
    if (braceCount > 0) {
      _dataBuffer.write(bufferContent);
    }
  }

  void _parseAndNotify(String jsonData) {
    try {
      final decodedJson = jsonDecode(jsonData);
      if (decodedJson is Map<String, dynamic>) {
        final now = DateTime.now();
        final recordData = Map<String, dynamic>.from(decodedJson);
        recordData['uniqueId'] =
            '${now.millisecondsSinceEpoch}_${Random().nextInt(9999)}';
        recordData['receivedTimestamp'] = now.millisecondsSinceEpoch;

        if (!recordData.containsKey('timestamp')) {
          recordData['timestamp'] = now.millisecondsSinceEpoch;
        }

        _lastReceivedTime = now;
        _lastReceivedTimeController.add(_lastReceivedTime);

        final trainRecord = TrainRecord.fromJson(recordData);
        _dataController.add(trainRecord);
        DatabaseService.instance.insertRecord(trainRecord);
      }
    } catch (e) {}
  }

  void _updateConnectionState(bool connected, String status) {
    if (connected) {
      _deviceStatus = "已连接";
    } else {
      _deviceStatus = status;
      _connectedDevice = null;
      _characteristic = null;
      _lastReceivedTime = null;
      _lastReceivedTimeController.add(null);
    }
    _statusController.add(_deviceStatus);
    _connectionController.add(connected);
  }

  void onAppResume() {
    ensureConnection();
  }

  void setAutoConnectBlocked(bool blocked) {
    _isAutoConnectBlocked = blocked;
  }

  bool get isConnected => _characteristic != null;

  String get deviceStatus => _deviceStatus;

  String? get deviceAddress => connectedDeviceAddress;

  String get connectedDeviceName {
    final liveName = _connectedDevice?.platformName.trim();
    if (liveName != null && liveName.isNotEmpty) return liveName;
    if (_lastKnownDeviceDisplayName != null &&
        _lastKnownDeviceDisplayName!.isNotEmpty) {
      return _lastKnownDeviceDisplayName!;
    }
    return _targetDeviceName;
  }

  String? get connectedDeviceAddress {
    final liveAddress = _connectedDevice?.remoteId.str;
    if (liveAddress != null && liveAddress.isNotEmpty) return liveAddress;
    return _lastKnownDeviceAddress;
  }

  bool get isScanning => FlutterBluePlus.isScanningNow;

  BluetoothDevice? get connectedDevice => _connectedDevice;

  bool get isManualDisconnect => _isManualDisconnect;

  void dispose() {
    _heartbeatTimer?.cancel();
    disconnect();
    _statusController.close();
    _dataController.close();
    _connectionController.close();
    _lastReceivedTimeController.close();
  }
}
