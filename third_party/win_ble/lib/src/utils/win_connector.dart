import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'ipc_decoder.dart';

class WinConnector {
  int _requestId = 0;
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;
  Process? _bleServer;
  final Map<int, Completer<dynamic>> _pending = {};
  final IpcDecoder _decoder = IpcDecoder();

  void _log(String message) {
    developer.log(message, name: 'WinBLE');
    // ignore: avoid_print
    print('[WinBLE] $message');
  }

  void _fail(Object error) {
    _log(error.toString());
    final calls = List<Completer<dynamic>>.of(_pending.values);
    _pending.clear();
    for (final call in calls) {
      if (!call.isCompleted) call.completeError(error);
    }
  }

  Future<void> initialize({
    Function(dynamic)? onData,
    required String serverPath,
  }) async {
    final process = await Process.start(serverPath, []);
    _bleServer = process;
    _stdoutSubscription = process.stdout.listen((bytes) {
      try {
        for (final data in _decoder.add(bytes)) {
          if (data is Map && data['_type'] == 'response') {
            final call = _pending.remove(data['_id']);
            if (data['error'] != null) {
              final error = data['error'].toString();
              _log('Request ${data['_id']}: $error');
              call?.completeError(error);
            } else {
              call?.complete(data['result']);
            }
          } else {
            onData?.call(data);
          }
        }
      } catch (error) {
        _fail(error);
      }
    }, onError: _fail);
    _stderrSubscription = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((text) => _log('stderr: $text'), onError: _fail);
    unawaited(
      process.exitCode.then((code) {
        if (identical(_bleServer, process)) {
          _bleServer = null;
          _fail(StateError('BLE helper exited ($code)'));
        }
      }),
    );
  }

  Future<dynamic> invokeMethod(
    String method, {
    Map<String, dynamic>? args,
    bool waitForResult = true,
  }) async {
    final process = _bleServer;
    if (process == null) throw StateError('BLE helper is not running');
    final id = _requestId++;
    final call = Completer<dynamic>();
    final future = waitForResult
        ? call.future.timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TimeoutException('WinBLE $method timed out'),
          )
        : null;
    if (waitForResult) _pending[id] = call;
    try {
      final payload = utf8.encode(
        jsonEncode({...?args, 'cmd': method, if (waitForResult) '_id': id}),
      );
      final header = ByteData(4)..setUint32(0, payload.length, Endian.little);
      process.stdin.add([...header.buffer.asUint8List(), ...payload]);
    } catch (error, stack) {
      if (waitForResult) {
        call.completeError(error, stack);
      } else {
        rethrow;
      }
    }
    try {
      return await future;
    } finally {
      _pending.remove(id);
    }
  }

  void dispose() {
    _stderrSubscription?.cancel();
    _stdoutSubscription?.cancel();
    _bleServer?.kill();
    _bleServer = null;
    _fail(StateError('BLE helper disposed'));
  }
}
