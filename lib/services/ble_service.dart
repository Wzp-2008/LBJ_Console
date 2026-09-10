import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'ble_diagnostics.dart';
import 'ble_protocol.dart';
import 'classic_spp_service.dart';
import 'recovery_ota.dart';

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
  final StreamController<Map<String, dynamic>> _deviceNameResultController =
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
  bool _initialized = false;
  StreamSubscription<BluetoothAdapterState>? _adapterSubscription;
  DateTime? _lastReceivedTime;

  bool _isConnecting = false;
  int _connectionGeneration = 0;
  BluetoothDevice? _connectingDevice;
  bool _gattReady = false;
  bool _adapterOn = false;
  bool _isManualDisconnect = false;
  bool _isAutoConnectBlocked = false;

  Timer? _heartbeatTimer;
  final BleJsonDecoder _dataDecoder = BleJsonDecoder();
  final BleJsonDecoder _otaDecoder = BleJsonDecoder();
  BluetoothCharacteristic? _otaControlCharacteristic;
  bool _otaActive = false;
  SppOtaTransport? _activeSppTransport;
  int _negotiatedMtu = 23;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await _loadSettings();
    BleDiagnostics.log(
      'Initialize; remembered MAC=$_lastKnownDeviceAddress; log=${BleDiagnostics.logPath}',
    );
    _adapterSubscription = FlutterBluePlus.adapterState.listen((state) {
      BleDiagnostics.log('Adapter state=$state');
      _adapterOn = state == BluetoothAdapterState.on;
      if (state == BluetoothAdapterState.on) {
        ensureConnection();
      } else {
        _onDisconnected(attemptReconnect: false);
        stopScan();
      }
    });
    _startHeartbeat();
    ensureConnection();
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
        _lastKnownDeviceAddress = settings['specifiedDeviceAddress'] as String?;
      }
    } catch (e, stack) {
      BleDiagnostics.log('Loading remembered device failed', e, stack);
    }
  }

  void ensureConnection() {
    if (!shouldReconnectBle(
      savedAddress: _lastKnownDeviceAddress,
      adapterOn: _adapterOn,
      connected: isConnected,
      connecting: _isConnecting,
      manuallyDisconnected: _isManualDisconnect,
      blocked: _isAutoConnectBlocked,
      otaActive: _otaActive,
    )) {
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

      if (target != null) {
        _isConnecting = false;
        await connect(target);
      } else {
        _isConnecting = false;
        await startScan(timeout: const Duration(seconds: 6));
      }
    } catch (e, stack) {
      BleDiagnostics.log("Reconnect failed", e, stack);
      _isConnecting = false;
    }
  }

  Future<void> startScan({
    Duration? timeout,
    Function(List<BluetoothDevice>)? onScanResults,
  }) async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }

    _statusController.add("正在扫描...");

    _scanResultsSubscription?.cancel();
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
      final allFoundDevices = results.map((r) => r.device).toList();

      onScanResults?.call(allFoundDevices);

      if (onScanResults != null ||
          _otaActive ||
          isConnected ||
          _isConnecting ||
          _isManualDisconnect ||
          _isAutoConnectBlocked) {
        return;
      }

      for (var device in allFoundDevices) {
        if (_shouldAutoConnectTo(device)) {
          stopScan();
          connect(device).catchError((Object error, StackTrace stack) {
            BleDiagnostics.log("Automatic connection failed", error, stack);
          });
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: timeout);
    } catch (e, stack) {
      BleDiagnostics.log("Scan failed", e, stack);
      _statusController.add("扫描失败");
      rethrow;
    }
  }

  bool _shouldAutoConnectTo(BluetoothDevice device) =>
      _lastKnownDeviceAddress != null &&
      _lastKnownDeviceAddress!.toUpperCase() ==
          device.remoteId.str.toUpperCase();

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _scanResultsSubscription?.cancel();
  }

  bool _isCurrentConnectionAttempt(int generation, BluetoothDevice device) =>
      generation == _connectionGeneration &&
      (identical(_connectingDevice, device) ||
          identical(_connectedDevice, device));

  void _checkConnectionAttempt(int generation, BluetoothDevice device) {
    if (!_isCurrentConnectionAttempt(generation, device)) {
      throw StateError('蓝牙连接尝试已失效');
    }
  }

  Future<void> connect(BluetoothDevice device) async {
    if (isConnected || _isConnecting) return;

    final generation = ++_connectionGeneration;
    _isConnecting = true;
    _connectingDevice = device;
    _isManualDisconnect = false;
    _statusController.add("正在连接: ${device.platformName}");
    BleDiagnostics.log(
      "Connecting MAC=${device.remoteId.str} name=${device.platformName}",
    );

    try {
      await _connectionStateSubscription?.cancel();
      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected &&
            _isCurrentConnectionAttempt(generation, device)) {
          _onDisconnected(connectionGeneration: generation);
        }
      });

      // If already connected at OS level, skip connect() and go straight to service discovery
      final systemConnected = FlutterBluePlus.connectedDevices;
      final alreadyConnected = systemConnected.any(
        (d) => d.remoteId == device.remoteId,
      );

      _checkConnectionAttempt(generation, device);
      if (!alreadyConnected) {
        await device.connect(timeout: const Duration(seconds: 15));
      } else if (Platform.isWindows) {
        // WinBle needs a short settle time before GATT discovery on existing links.
        await Future.delayed(const Duration(milliseconds: 400));
      }
      _checkConnectionAttempt(generation, device);
      await _onConnected(device, generation);
      _checkConnectionAttempt(generation, device);
      _isConnecting = false;
      _connectingDevice = null;
    } catch (e, stack) {
      BleDiagnostics.log("Connection failed", e, stack);
      if (_isCurrentConnectionAttempt(generation, device)) {
        _onDisconnected(
          attemptReconnect: false,
          connectionGeneration: generation,
        );
      }
      try {
        await device.disconnect();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _onConnected(BluetoothDevice device, int generation) async {
    await _discoverServicesAndSetupNotifications(device, generation);
    _checkConnectionAttempt(generation, device);
    if (isConnected) {
      await _rememberDeviceIdentity(device, generation);
      _checkConnectionAttempt(generation, device);
    }
  }

  Future<void> _rememberDeviceIdentity(
    BluetoothDevice device,
    int generation,
  ) async {
    final address = device.remoteId.str;
    if (address.isNotEmpty) {
      _checkConnectionAttempt(generation, device);
      try {
        await DatabaseService.instance.setSetting(
          'specifiedDeviceAddress',
          address,
        );
      } catch (e, stack) {
        BleDiagnostics.log('Cannot persist device MAC', e, stack);
      }
      _checkConnectionAttempt(generation, device);
      _lastKnownDeviceAddress = address;
    }
    final name = device.platformName.trim();
    if (name.isNotEmpty) {
      _checkConnectionAttempt(generation, device);
      _lastKnownDeviceDisplayName = name;
    }
  }

  Future<List<BluetoothService>> _discoverServicesWithRetry(
    BluetoothDevice device, {
    int? generation,
    int attempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        if (generation != null) _checkConnectionAttempt(generation, device);
        if (attempt > 0) {
          await Future.delayed(Duration(milliseconds: 350 * attempt));
          if (generation != null) {
            _checkConnectionAttempt(generation, device);
          }
        }
        final services = await device.discoverServices();
        if (generation != null) _checkConnectionAttempt(generation, device);
        return services;
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
    List<BluetoothService> services, {
    int? generation,
    BluetoothDevice? device,
  }) async {
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
          if (generation != null && device != null) {
            _checkConnectionAttempt(generation, device);
          }
          bool write = c.properties.write || c.properties.writeWithoutResponse;
          if (Platform.isWindows) {
            final prop = (c as BluetoothCharacteristicWindows).propertiesWinBle;
            write = prop.write == true || prop.writeWithoutResponse == true;
          }
          if (write) {
            await c.write(payload);
            if (generation != null && device != null) {
              _checkConnectionAttempt(generation, device);
            }
          }
        } catch (_) {}
      }
    }
  }

  Future<void> _discoverServicesAndSetupNotifications(
    BluetoothDevice device,
    int generation,
  ) async {
    try {
      final services = await _discoverServicesWithRetry(
        device,
        generation: generation,
      );
      _checkConnectionAttempt(generation, device);

      BluetoothCharacteristic? mainCharacteristic;
      BluetoothCharacteristic? otaControl;
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
          }
        }
      }
      if (mainCharacteristic == null && otaControl == null) {
        throw Exception('LBJ GATT service not found');
      }

      // Windows queries the negotiated size; it does not update mtuNow.
      _negotiatedMtu = await device.requestMtu(247);
      _checkConnectionAttempt(generation, device);
      BleDiagnostics.log(
        'GATT ready MAC=${device.remoteId.str} MTU=$_negotiatedMtu OTA=${otaControl != null}',
      );
      await _valueSubscription?.cancel();
      await _otaControlSubscription?.cancel();
      _dataDecoder.clear();
      _otaDecoder.clear();
      if (mainCharacteristic != null) {
        _valueSubscription = mainCharacteristic.onValueReceived.listen(
          _onDataReceived,
        );
        await mainCharacteristic.setNotifyValue(true);
        _checkConnectionAttempt(generation, device);
      }

      if (otaControl != null) {
        _otaControlCharacteristic = otaControl;
        _otaControlSubscription = otaControl.onValueReceived.listen(
          _onOtaControlReceived,
        );
        await otaControl.setNotifyValue(true);
        _checkConnectionAttempt(generation, device);
      }

      _checkConnectionAttempt(generation, device);
      _characteristic = mainCharacteristic;
      _otaControlCharacteristic = otaControl;
      _connectedDevice = device;
      _updateConnectionState(true, "已连接");
      _isConnecting = false;
      _connectingDevice = null;
      // Read before TIME overwrites the characteristic's cached version value.
      try {
        if (mainCharacteristic != null) await mainCharacteristic.read();
      } catch (_) {
        // Older firmware may only support version notifications.
      }
      _checkConnectionAttempt(generation, device);
      await _writeTimeSyncToWritableCharacteristics(
        services,
        generation: generation,
        device: device,
      );
      _checkConnectionAttempt(generation, device);
    } catch (e) {
      if (_isCurrentConnectionAttempt(generation, device)) {
        _isConnecting = false;
        await _valueSubscription?.cancel();
        await _otaControlSubscription?.cancel();
        _valueSubscription = null;
        _otaControlSubscription = null;
        _characteristic = null;
        _otaControlCharacteristic = null;
        _connectingDevice = null;
        try {
          await device.disconnect();
        } catch (_) {}
        _onDisconnected(
          attemptReconnect: false,
          connectionGeneration: generation,
        );
      } else {
        // A newer attempt owns all shared fields. Only tear down this stale
        // device; never cancel the new attempt's subscriptions.
        try {
          await device.disconnect();
        } catch (_) {}
      }
      rethrow;
    }
  }

  void _onDisconnected({
    bool attemptReconnect = true,
    int? connectionGeneration,
  }) {
    if (connectionGeneration != null &&
        connectionGeneration != _connectionGeneration) {
      return;
    }
    _connectionGeneration++;
    BleDiagnostics.log("Disconnected; OTA=$_otaActive");
    _updateConnectionState(false, "连接已断开");
    _connectionStateSubscription?.cancel();
    _valueSubscription?.cancel();
    _otaControlSubscription?.cancel();
    _dataDecoder.clear();
    _otaDecoder.clear();

    _isConnecting = false;
    _connectingDevice = null;
    // Heartbeat retries; do not recursively reconnect inside failure cleanup.
  }

  Future<void> connectManually(BluetoothDevice device) async {
    _isManualDisconnect = false;
    _isAutoConnectBlocked = false;
    if (_otaActive) throw StateError("固件升级期间不能切换设备");
    await stopScan();
    await connect(device);
  }

  Future<void> disconnect() async {
    _isManualDisconnect = true;
    await stopScan();
    ++_connectionGeneration;

    await _connectionStateSubscription?.cancel();
    await _valueSubscription?.cancel();
    await _otaControlSubscription?.cancel();
    _valueSubscription = null;
    _otaControlSubscription = null;

    final device = _connectedDevice ?? _connectingDevice;
    _characteristic = null;
    _otaControlCharacteristic = null;
    _connectedDevice = null;
    _connectingDevice = null;

    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    _onDisconnected(attemptReconnect: false);
  }

  void _onDataReceived(List<int> value) {
    try {
      for (final decoded in _dataDecoder.add(value)) {
        _parseAndNotify(jsonEncode(decoded));
      }
    } catch (e, stack) {
      BleDiagnostics.log('Invalid BLE JSON', e, stack);
    }
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
      for (final state in _otaDecoder.add(value)) {
        if (state.containsKey('state')) _otaStateController.add(state);
      }
    } catch (e, stack) {
      BleDiagnostics.log('Invalid OTA status', e, stack);
    }
  }

  Future<void> startFirmwareOta(
    File firmware, {
    required String sha256,
    void Function(Map<String, dynamic> state)? onState,
    void Function(double progress)? onProgress,
  }) async {
    final address = _connectedDevice?.remoteId.str;
    if (!isConnected || _otaControlCharacteristic == null || address == null) {
      throw StateError('Main OTA 控制服务不可用，请先连接支持 OTA 的接收机');
    }
    if (_otaActive || _renaming) throw StateError('设备操作正在进行');
    _otaActive = true;
    try {
      await stopScan();
      BleDiagnostics.log(
        'OTA begin MAC=$address file=${firmware.path} SHA256=$sha256',
      );
      Future<SppOtaTransport> connectSpp() async {
        BleDiagnostics.log('Connecting Classic SPP MAC=$address');
        final transport = await ClassicSppService.connectOtaTransport(address);
        _activeSppTransport = transport;
        return transport;
      }

      final total = await firmware.length();
      Future<void> transferFromUpdaterStart() => SppRecoveryOta(
        connectSpp: connectSpp,
        onState: onState,
        onProgress: onProgress,
        log: BleDiagnostics.log,
      ).run(firmware.openRead(), total, sha256);

      try {
        await RecoveryOta(
          _BleMainOtaTransport(this),
          connectSpp: connectSpp,
          onState: onState,
          onProgress: onProgress,
          log: BleDiagnostics.log,
        ).run(firmware.openRead(), total, sha256);
      } on SppAckTimeoutException {
        // RecoveryOta has already closed the timed-out SPP session and the
        // device is still in Updater mode. Restart only the SPP OTA session;
        // do not send the Main BLE switch command a second time.
        BleDiagnostics.log(
          'SPP ACK timeout; reconnecting and restarting OTA from START',
        );
        await transferFromUpdaterStart();
      }
    } catch (e, stack) {
      BleDiagnostics.log('OTA failed MAC=$address', e, stack);
      rethrow;
    } finally {
      _activeSppTransport = null;
      _otaActive = false;
      ensureConnection();
    }
  }

  Future<void> cancelFirmwareOta() async {
    if (_activeSppTransport?.connected == true) {
      await _activeSppTransport!.control('CANCEL');
    } else if (_otaActive && _otaControlCharacteristic != null) {
      await _otaControlCharacteristic!.write(utf8.encode('CANCEL'));
    }
  }

  bool _renaming = false;

  /// Write a NAME command to the connected receiver's legacy FFE1 channel
  /// and wait for its persisted-result notification.
  Future<void> setRemoteDeviceName(String name) async {
    final characteristic = _characteristic;
    final device = _connectedDevice;
    if (!isConnected || characteristic == null || device == null) {
      throw StateError('蓝牙设备未连接');
    }

    if (_otaActive || _renaming) throw StateError("设备操作正在进行");
    final normalized = name.trim();
    final nameBytes = utf8.encode(normalized);
    if (nameBytes.isEmpty) throw ArgumentError('设备名称不能为空');
    if (nameBytes.length > 16) {
      throw ArgumentError('设备名称 UTF-8 编码不能超过 16 字节');
    }
    if (normalized.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      throw ArgumentError('设备名称不能包含控制字符');
    }

    final command = utf8.encode('NAME:$normalized');
    final maxPayload = max(_negotiatedMtu - 3, 20);
    if (command.length > maxPayload) {
      throw StateError('当前蓝牙 MTU 不足以发送该设备名称，请重新连接后再试');
    }

    _renaming = true;
    final completer = Completer<Map<String, dynamic>>();
    final subscription = _deviceNameResultController.stream.listen((result) {
      if (!completer.isCompleted &&
          (result['state'] == 'error' ||
              (result['state'] == 'saved' && result['name'] == normalized))) {
        completer.complete(result);
      }
    });
    final disconnected = connectionStream.listen((connected) {
      if (!connected && !completer.isCompleted) {
        completer.complete({'state': 'error', 'message': '保存名称时设备断开'});
      }
    });
    try {
      BleDiagnostics.log(
        'Rename request MAC=${device.remoteId.str} name=$normalized',
      );
      await characteristic.write(command).timeout(const Duration(seconds: 10));
      final result = await completer.future.timeout(
        const Duration(seconds: 10),
      );
      if (result['state'] != 'saved') {
        throw StateError(result['message']?.toString() ?? '设备拒绝了名称修改请求');
      }
      _lastKnownDeviceDisplayName = normalized;
      BleDiagnostics.log('Rename saved; reboot required');
    } catch (e, stack) {
      BleDiagnostics.log('Rename failed', e, stack);
      rethrow;
    } finally {
      await subscription.cancel();
      await disconnected.cancel();
      _renaming = false;
    }
  }

  void _parseAndNotify(String jsonData) {
    try {
      final decodedJson = jsonDecode(jsonData);
      if (decodedJson is Map<String, dynamic>) {
        if (_tryHandleFirmwareVersion(decodedJson)) return;
        if (_tryHandleDeviceNameResult(decodedJson)) return;
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

  bool _tryHandleDeviceNameResult(Map<String, dynamic> decoded) {
    if (decoded['type']?.toString() != 'device_name') return false;
    _deviceNameResultController.add(decoded);
    return true;
  }

  void _updateConnectionState(bool connected, String status) {
    _gattReady = connected;
    if (connected) {
      _deviceStatus = "已连接";
    } else {
      _deviceStatus = status;
      _connectedDevice = null;
      _characteristic = null;
      _otaControlCharacteristic = null;
      _firmwareVersion = null;
      _negotiatedMtu = 23;
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

  bool get isConnected =>
      _gattReady &&
      _connectedDevice != null &&
      (_characteristic != null || _otaControlCharacteristic != null);

  bool get isOtaActive => _otaActive;

  bool get canChangeDeviceName => _characteristic != null && isConnected;

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
    return "未命名设备";
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
    _adapterSubscription?.cancel();
    disconnect();
    _statusController.close();
    _dataController.close();
    _connectionController.close();
    _lastReceivedTimeController.close();
    _firmwareVersionController.close();
    _otaStateController.close();
    _deviceNameResultController.close();
  }
}

class _BleMainOtaTransport implements MainOtaTransport {
  _BleMainOtaTransport(this.ble);
  final BLEService ble;
  @override
  Stream<Map<String, dynamic>> get states => ble.otaStateStream;
  @override
  Stream<bool> get connections => ble.connectionStream;
  @override
  bool get connected => ble.isConnected;
  @override
  int get maxControlPayload => max(ble._negotiatedMtu - 3, 20);
  @override
  Future<void> control(String command) async {
    final characteristic = ble._otaControlCharacteristic;
    if (characteristic == null) throw StateError('OTA 控制连接已断开');
    await characteristic
        .write(
          utf8.encode(command),
          withoutResponse:
              !characteristic.properties.write &&
              characteristic.properties.writeWithoutResponse,
        )
        .timeout(const Duration(seconds: 15));
  }
}
