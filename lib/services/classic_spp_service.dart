import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';

import 'ble_diagnostics.dart';
import 'ble_protocol.dart';
import 'recovery_ota.dart';

abstract interface class ClassicSppConnection {
  Stream<List<int>> get data;
  Stream<void> get disconnected;
  bool get isConnected;
  Future<void> write(List<int> bytes);
  Future<void> close();
}

class ClassicBluetoothDevice {
  const ClassicBluetoothDevice({required this.device, required this.isPaired});

  final BtcDevice device;
  final bool isPaired;

  String get address => device.address;
  String get displayName => device.displayName;
  List<String> get serviceUuids => device.uuids;
  bool get hasSppService => serviceUuids.any(
    (uuid) =>
        ClassicSppService.normalizeUuid(uuid) ==
        ClassicSppService.normalizeUuid(BtcUuid.spp),
  );
}

class ClassicSppService {
  static Future<ClassicSppConnection> connect(String address) async {
    if (Platform.isAndroid) return _AndroidSppConnection.open(address);
    if (Platform.isWindows) return _WindowsSppConnection.open(address);
    throw UnsupportedError('当前平台不支持 Classic Bluetooth SPP OTA');
  }

  /// Discovers all nearby Classic Bluetooth devices and merges them with the
  /// paired-device list so the caller can present an explicit choice.
  static Future<List<ClassicBluetoothDevice>> discoverDevices({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (!Platform.isAndroid && !Platform.isWindows) {
      throw UnsupportedError('当前平台不支持 Classic Bluetooth SPP 搜索');
    }

    final native = FlutterClassicBluetooth();
    final paired = await native.getPairedDevices();
    final discovered = await native.scan(timeout: timeout);
    final byAddress = <String, BtcDevice>{};
    for (final device in paired) {
      byAddress[device.address] = device;
    }
    for (final device in discovered) {
      final previous = byAddress[device.address];
      byAddress[device.address] = previous == null
          ? device
          : previous.mergedWith(device);
    }

    final pairedAddresses = paired.map((device) => device.address).toSet();
    final result = byAddress.values
        .map(
          (device) => ClassicBluetoothDevice(
            device: device,
            isPaired:
                pairedAddresses.contains(device.address) ||
                device.bondState == BtcBondState.bonded,
          ),
        )
        .toList();
    result.sort((a, b) {
      if (a.isPaired != b.isPaired) return a.isPaired ? -1 : 1;
      if (a.hasSppService != b.hasSppService) {
        return a.hasSppService ? -1 : 1;
      }
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return result;
  }

  static Future<bool> pair(String address) {
    return FlutterClassicBluetooth().bondDevice(address);
  }

  /// Opens a connection and exposes it as the OTA transport used by the
  /// Updater SPP protocol.
  static Future<SppOtaTransport> connectOtaTransport(String address) async {
    return _ClassicSppOtaTransport(await connect(address));
  }

  static String normalizeUuid(String value) =>
      value.trim().replaceAll('{', '').replaceAll('}', '').toLowerCase();
}

class _AndroidSppConnection implements ClassicSppConnection {
  _AndroidSppConnection._();

  static const _channel = MethodChannel('lbjconsole/classic_spp');
  static _AndroidSppConnection? _active;
  final _data = StreamController<List<int>>();
  final _disconnected = StreamController<void>.broadcast();
  bool _connected = false;
  bool _closed = false;

  static Future<_AndroidSppConnection> open(String address) async {
    await _active?.close();
    final connection = _AndroidSppConnection._();
    _active = connection;
    _channel.setMethodCallHandler((call) async {
      final current = _active;
      if (current == null || current._closed) return;
      switch (call.method) {
        case 'data':
          current._data.add(List<int>.from(call.arguments as Uint8List));
          break;
        case 'disconnected':
          current._markDisconnected();
          break;
        case 'error':
          BleDiagnostics.log('Android SPP: ${call.arguments}');
          break;
      }
    });
    try {
      await _channel
          .invokeMethod<void>('connect', {'address': address})
          .timeout(const Duration(seconds: 30));
      connection._connected = true;
      return connection;
    } catch (_) {
      try {
        await _channel.invokeMethod<void>('disconnect');
      } catch (_) {}
      connection._closed = true;
      if (identical(_active, connection)) _active = null;
      // No caller can be listening because open() did not return. A
      // single-subscription controller's close future waits forever in this
      // situation, so initiate closure without awaiting that future.
      unawaited(connection._data.close());
      unawaited(connection._disconnected.close());
      rethrow;
    }
  }

  void _markDisconnected() {
    if (!_connected) return;
    _connected = false;
    _disconnected.add(null);
  }

  @override
  Stream<List<int>> get data => _data.stream;
  @override
  Stream<void> get disconnected => _disconnected.stream;
  @override
  bool get isConnected => _connected && !_closed;

  @override
  Future<void> write(List<int> bytes) => _channel
      .invokeMethod<void>('write', {'data': Uint8List.fromList(bytes)})
      .timeout(const Duration(seconds: 20));

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connected = false;
    try {
      await _channel.invokeMethod<void>('disconnect');
    } catch (_) {}
    if (identical(_active, this)) _active = null;
    await _data.close();
    await _disconnected.close();
  }
}

class _WindowsSppConnection implements ClassicSppConnection {
  _WindowsSppConnection._(this._connection);

  final BtcConnection _connection;
  final _disconnected = StreamController<void>.broadcast();
  StreamSubscription<BtcConnectionState>? _stateSubscription;
  bool _connected = false;
  bool _closed = false;

  static Future<_WindowsSppConnection> open(String address) async {
    final native = FlutterClassicBluetooth();
    final link = await native.connect(
      address: address,
      uuid: BtcUuid.spp,
      // Match the existing Android path and the old bridge: the device is
      // paired by Windows, while the RFCOMM link itself need not require an
      // authenticated connection.
      secure: false,
      timeout: const Duration(seconds: 10),
    );
    final connection = _WindowsSppConnection._(link);
    connection._connected = link.isConnected;
    connection._stateSubscription = link.stateStream.listen((state) {
      if (state == BtcConnectionState.disconnected) {
        connection._markDisconnected();
      }
    });
    if (!connection._connected) {
      await connection.close();
      throw StateError('Classic SPP 连接已断开');
    }
    return connection;
  }

  @override
  Stream<List<int>> get data =>
      _connection.input.map((bytes) => bytes.toList());
  @override
  Stream<void> get disconnected => _disconnected.stream;
  @override
  bool get isConnected => _connected && !_closed;

  @override
  Future<void> write(List<int> bytes) async {
    if (!isConnected) throw StateError('Classic SPP 已断开');
    await _connection.output
        .writeBytes(bytes)
        .timeout(const Duration(seconds: 20));
  }

  void _markDisconnected() {
    if (!_connected) return;
    _connected = false;
    if (!_disconnected.isClosed) _disconnected.add(null);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connected = false;
    await _stateSubscription?.cancel();
    try {
      await _connection.close();
    } catch (error, stack) {
      BleDiagnostics.log('Classic SPP close failed', error, stack);
    } finally {
      _connection.dispose();
      if (!_disconnected.isClosed) await _disconnected.close();
    }
  }
}

class _ClassicSppOtaTransport implements SppOtaTransport {
  _ClassicSppOtaTransport(this.connection) {
    _dataSubscription = connection.data.listen(
      _onData,
      onError: (Object error, StackTrace stack) {
        BleDiagnostics.log('SPP receive failed', error, stack);
        if (!_ready.isCompleted) _ready.completeError(error, stack);
      },
    );
    _disconnectSubscription = connection.disconnected.listen((_) {
      if (!_ready.isCompleted) {
        _ready.completeError(StateError('收到 Updater 握手前 SPP 已断开'));
      }
    });
  }

  final ClassicSppConnection connection;
  final SppLineDecoder _decoder = SppLineDecoder();
  final StreamController<Map<String, dynamic>> _states =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final Completer<void> _ready = Completer<void>();
  StreamSubscription<List<int>>? _dataSubscription;
  StreamSubscription<void>? _disconnectSubscription;

  void _onData(List<int> bytes) {
    try {
      final lines = _decoder.add(bytes);
      for (final line in lines) {
        try {
          if (line.isEmpty) continue;
          if (line == 'LBJ Train Warning Ready') {
            BleDiagnostics.log('SPP handshake received');
            if (!_ready.isCompleted) _ready.complete();
            continue;
          }
          BleDiagnostics.log('SPP receive: $line');
          if (!line.startsWith('{')) continue;
          final decoded = jsonDecode(line);
          if (decoded is! Map) continue;
          final message = Map<String, dynamic>.from(decoded);
          if (message['state'] == 'idle' && !_ready.isCompleted) {
            _ready.complete();
          }
          if (message['state'] == 'error' || message['state'] == 'aborted') {
            BleDiagnostics.log(
              'SPP terminal status: ${message['state']} '
              'code=${message['code'] ?? 'unknown'}',
            );
          }
          if (message.containsKey('state')) _states.add(message);
        } catch (error, stack) {
          // A malformed status line must not hide a later idle/terminal
          // status that arrived in the same RFCOMM read.
          BleDiagnostics.log('Invalid SPP status line', error, stack);
        }
      }
    } catch (error, stack) {
      BleDiagnostics.log('Invalid SPP status stream', error, stack);
      if (!_ready.isCompleted) _ready.completeError(error, stack);
    }
  }

  @override
  Stream<Map<String, dynamic>> get states => _states.stream;

  @override
  Stream<void> get disconnected => connection.disconnected;

  @override
  Future<void> get ready => _ready.future;

  @override
  bool get connected => connection.isConnected;

  @override
  // The Updater accepts at most 4096 payload bytes per OTAD frame. The OTA
  // runner sends one frame at a time and waits for its ACK before continuing.
  int get maxPayload => 4096;

  @override
  Future<void> control(String command) {
    BleDiagnostics.log('SPP control: $command');
    return connection.write(utf8.encode('$command\n'));
  }

  @override
  Future<void> write(List<int> frame) async {
    BleDiagnostics.log('SPP data write ${frame.length} bytes');
    await connection.write(frame);
  }

  @override
  Future<void> close() async {
    await _dataSubscription?.cancel();
    await _disconnectSubscription?.cancel();
    await connection.close();
    await _states.close();
  }
}
