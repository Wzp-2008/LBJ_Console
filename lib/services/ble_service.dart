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
  static final Guid otaServiceUuid = Guid(
    "0000fff0-0000-1000-8000-00805f9b34fb",
  );
  static final Guid otaControlUuid = Guid(
    "0000fff1-0000-1000-8000-00805f9b34fb",
  );
  static final Guid otaDataUuid = Guid("0000fff2-0000-1000-8000-00805f9b34fb");

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _characteristic;
  StreamSubscription<List<int>>? _valueSubscription;
  StreamSubscription<List<int>>? _otaControlSubscription;
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
  final StreamController<String> _firmwareVersionController =
      StreamController<String>.broadcast();
  final StreamController<Map<String, dynamic>> _otaStateController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<String> get statusStream => _statusController.stream;

  Stream<TrainRecord> get dataStream => _dataController.stream;

  Stream<bool> get connectionStream => _connectionController.stream;

  Stream<DateTime?> get lastReceivedTimeStream =>
      _lastReceivedTimeController.stream;

  Stream<String> get firmwareVersionStream => _firmwareVersionController.stream;

  Stream<Map<String, dynamic>> get otaStateStream => _otaStateController.stream;

  String _deviceStatus = "未连接";
  String? _lastKnownDeviceAddress;
  String? _lastKnownDeviceDisplayName;
  String? _firmwareVersion;
  String _targetDeviceName = "LBJReceiver";
  DateTime? _lastReceivedTime;

  bool _isConnecting = false;
  bool _isManualDisconnect = false;
  bool _isAutoConnectBlocked = false;

  Timer? _heartbeatTimer;
  final StringBuffer _dataBuffer = StringBuffer();
  BluetoothCharacteristic? _otaControlCharacteristic;
  BluetoothCharacteristic? _otaDataCharacteristic;
  Completer<void>? _otaTerminalCompleter;
  Completer<void>? _otaReadyCompleter;
  bool _otaActive = false;
  Object? _otaError;

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
          (d) =>
              d!.platformName.toLowerCase() == _targetDeviceName.toLowerCase(),
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
      final alreadyConnected = systemConnected.any(
        (d) => d.remoteId == device.remoteId,
      );

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
      if (service.uuid != serviceUuid) continue;
      for (final c in service.characteristics) {
        if (c.uuid != charUuid) continue;
        try {
          bool write = c.properties.write || c.properties.writeWithoutResponse;
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

      BluetoothCharacteristic? mainCharacteristic;
      BluetoothCharacteristic? otaControl;
      BluetoothCharacteristic? otaData;
      for (var service in services) {
        if (service.uuid == serviceUuid) {
          for (var char in service.characteristics) {
            if (char.uuid == charUuid) {
              mainCharacteristic = char;
            }
          }
        }
        if (service.uuid == otaServiceUuid) {
          for (var char in service.characteristics) {
            if (char.uuid == otaControlUuid) otaControl = char;
            if (char.uuid == otaDataUuid) otaData = char;
          }
        }
      }
      if (mainCharacteristic == null) {
        throw Exception('LBJ GATT service not found');
      }

      _characteristic = mainCharacteristic;
      _connectedDevice = device;
      if (Platform.isAndroid) await device.requestMtu(512);
      await _valueSubscription?.cancel();
      await _otaControlSubscription?.cancel();
      _dataBuffer.clear();
      _valueSubscription = mainCharacteristic.lastValueStream.listen(
        _onDataReceived,
      );
      await mainCharacteristic.setNotifyValue(true);

      if (otaControl != null && otaData != null) {
        _otaControlCharacteristic = otaControl;
        _otaDataCharacteristic = otaData;
        _otaControlSubscription = otaControl.lastValueStream.listen(
          _onOtaControlReceived,
        );
        await otaControl.setNotifyValue(true);
      }

      _updateConnectionState(true, "已连接");
      _isConnecting = false;
      // Read before TIME overwrites the characteristic's cached version value.
      try {
        await mainCharacteristic.read();
      } catch (_) {
        // Older firmware may only support version notifications.
      }
      await _writeTimeSyncToWritableCharacteristics(services);
    } catch (e) {
      _isConnecting = false;
      await _valueSubscription?.cancel();
      await _otaControlSubscription?.cancel();
      _valueSubscription = null;
      _otaControlSubscription = null;
      _characteristic = null;
      _otaControlCharacteristic = null;
      _otaDataCharacteristic = null;
      try {
        await device.disconnect();
      } catch (_) {}
      _onDisconnected(attemptReconnect: true);
    }
  }

  void _onDisconnected({bool attemptReconnect = true}) {
    final wasConnected = isConnected;
    if (_otaActive) {
      _otaError ??= StateError('蓝牙连接已断开，OTA 已中止');
      if (_otaReadyCompleter != null && !_otaReadyCompleter!.isCompleted) {
        _otaReadyCompleter!.complete();
      }
      if (_otaTerminalCompleter != null &&
          !_otaTerminalCompleter!.isCompleted) {
        _otaTerminalCompleter!.complete();
      }
    }
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
    await _otaControlSubscription?.cancel();
    _valueSubscription = null;
    _otaControlSubscription = null;

    final device = _connectedDevice;
    _characteristic = null;
    _otaControlCharacteristic = null;
    _otaDataCharacteristic = null;
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
      if (_otaActive) return;
      _dataBuffer.write(data);
      _processDataBuffer();
    } catch (e) {}
  }

  bool _tryHandleFirmwareVersion(Object? decoded) {
    if (decoded is! Map || decoded['type']?.toString() != 'firmware_version') {
      return false;
    }
    final version = decoded['version']?.toString();
    if (version != null && version.isNotEmpty) {
      _firmwareVersion = version;
      _firmwareVersionController.add(version);
    }
    return true;
  }

  void _onOtaControlReceived(List<int> value) {
    try {
      final decoded = jsonDecode(utf8.decode(value));
      if (decoded is! Map) return;
      final state = Map<String, dynamic>.from(decoded);
      _otaStateController.add(state);
      final name = state['state']?.toString();
      if (name == 'receiving') {
        if (_otaReadyCompleter != null && !_otaReadyCompleter!.isCompleted) {
          _otaReadyCompleter!.complete();
        }
      }
      if (name == 'error' || name == 'aborted' || name == 'success') {
        if (name == 'error' || name == 'aborted') {
          _otaError = Exception(state['code'] ?? 'OTA failed');
        }
        if (_otaReadyCompleter != null && !_otaReadyCompleter!.isCompleted) {
          _otaError ??= StateError('设备尚未开始接收就结束了 OTA');
          _otaReadyCompleter!.complete();
        }
        if (_otaTerminalCompleter != null &&
            !_otaTerminalCompleter!.isCompleted) {
          _otaTerminalCompleter!.complete();
        }
      }
    } catch (_) {}
  }

  Future<void> startFirmwareOta(
    File firmware, {
    required String sha256,
    void Function(Map<String, dynamic> state)? onState,
    void Function(double progress)? onProgress,
  }) async {
    final control = _otaControlCharacteristic;
    final dataCharacteristic = _otaDataCharacteristic;
    final device = _connectedDevice;
    if (!isConnected ||
        control == null ||
        dataCharacteristic == null ||
        device == null) {
      throw StateError('OTA 服务不可用，请先连接支持 OTA 的接收机');
    }
    if (_otaActive) throw StateError('已有 OTA 升级正在进行');

    final subscription = otaStateStream.listen((state) {
      onState?.call(state);
      final received = state['received'];
      final total = state['total'];
      if (received is num && total is num && total > 0) {
        onProgress?.call((received / total).clamp(0.0, 1.0));
      }
    });
    _otaActive = true;
    _otaError = null;
    try {
      final total = await firmware.length();
      if (total <= 0) throw StateError('固件文件为空');
      if (sha256.length != 64 ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
        throw ArgumentError.value(sha256, 'sha256', 'SHA-256 格式错误');
      }
      _otaReadyCompleter = Completer<void>();
      await control.write(
        utf8.encode(
          jsonEncode({'cmd': 'start', 'total': total, 'sha256': sha256}),
        ),
      );
      await _otaReadyCompleter!.future.timeout(const Duration(seconds: 10));
      if (_otaError != null) throw _otaError!;

      final chunkSize = min(max(device.mtuNow - 3, 20), 512);
      var sent = 0;
      await for (final chunk in firmware.openRead()) {
        for (var offset = 0; offset < chunk.length; offset += chunkSize) {
          if (_otaError != null) throw _otaError!;
          final end = min(offset + chunkSize, chunk.length);
          await dataCharacteristic.write(
            chunk.sublist(offset, end),
            withoutResponse: false,
          );
          sent += end - offset;
          onProgress?.call(sent / total);
        }
      }
      if (_otaError != null) throw _otaError!;
      _otaTerminalCompleter = Completer<void>();
      await control.write(utf8.encode('{"cmd":"finish"}'));
      await _otaTerminalCompleter!.future.timeout(const Duration(seconds: 30));
      if (_otaError != null) throw _otaError!;
    } catch (_) {
      if (isConnected && identical(device, _connectedDevice)) {
        try {
          await control.write(utf8.encode('{"cmd":"cancel"}'));
        } catch (_) {
          // Preserve the original transfer error if cancellation also fails.
        }
      }
      rethrow;
    } finally {
      await subscription.cancel();
      _otaReadyCompleter = null;
      _otaTerminalCompleter = null;
      _otaActive = false;
    }
  }

  Future<void> cancelFirmwareOta() async {
    if (_otaActive && _otaControlCharacteristic != null) {
      await _otaControlCharacteristic!.write(utf8.encode('{"cmd":"cancel"}'));
    }
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
        if (_tryHandleFirmwareVersion(decodedJson)) return;
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
      _otaControlCharacteristic = null;
      _otaDataCharacteristic = null;
      _firmwareVersion = null;
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

  String? get firmwareVersion => _firmwareVersion;

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
    _firmwareVersionController.close();
    _otaStateController.close();
  }
}
