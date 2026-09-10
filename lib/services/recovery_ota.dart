import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'ble_protocol.dart';

abstract interface class MainOtaTransport {
  Stream<Map<String, dynamic>> get states;
  Stream<bool> get connections;
  bool get connected;
  int get maxControlPayload;
  Future<void> control(String command);
}

abstract interface class SppOtaTransport {
  Stream<Map<String, dynamic>> get states;
  Stream<void> get disconnected;
  Future<void> get ready;
  bool get connected;
  int get maxPayload;
  Future<void> control(String command);
  Future<void> write(List<int> frame);
  Future<void> close();
}

typedef SppConnector = Future<SppOtaTransport> Function();

/// Lets a pending SPP operation be interrupted by a terminal device status.
/// A write may otherwise keep the transfer loop busy while the Updater has
/// already rejected the session.
Future<void> _raceSppOperation(
  Future<void> operation,
  Future<Object> terminalError,
) {
  return Future.any<void>([
    operation,
    terminalError.then<void>((error) => throw error),
  ]);
}

int? _jsonInt(Object? value) {
  if (value is int) return value;
  if (value is num && value == value.truncate()) return value.toInt();
  return null;
}

/// The current Updater protocol does not permit retransmitting a block after
/// an ACK timeout. The SPP session must be closed and the whole OTA restarted.
class SppAckTimeoutException extends TimeoutException {
  SppAckTimeoutException(this.expectedReceived, Duration timeout)
    : super(
        '等待 OTA ACK 超时，期待 received=$expectedReceived；连接将断开，请从头重新开始 OTA',
        timeout,
      );

  final int expectedReceived;
}

Future<int> _waitForSppAck({
  required List<int> pendingAcks,
  required int expectedReceived,
  required Duration timeout,
  required Future<Object> terminalError,
}) async {
  final watch = Stopwatch()..start();
  while (pendingAcks.isEmpty) {
    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero) {
      throw SppAckTimeoutException(expectedReceived, timeout);
    }
    final wait = remaining < const Duration(milliseconds: 20)
        ? remaining
        : const Duration(milliseconds: 20);
    await _raceSppOperation(Future<void>.delayed(wait), terminalError);
  }

  final received = pendingAcks.removeAt(0);
  if (received != expectedReceived) {
    throw StateError(
      'Updater SPP ACK received=$received，期待 received=$expectedReceived',
    );
  }
  return received;
}

/// Normalize arbitrary source stream chunks into protocol-sized payloads.
/// File streams are allowed to choose their own chunk boundaries; those
/// boundaries must not turn a normal 4096-byte block into several smaller
/// in-flight blocks.
Stream<List<int>> _fixedSppPayloads(
  Stream<List<int>> firmware,
  int maxPayload,
) async* {
  final buffer = <int>[];
  await for (final chunk in firmware) {
    buffer.addAll(chunk);
    while (buffer.length >= maxPayload) {
      yield List<int>.of(buffer.getRange(0, maxPayload));
      buffer.removeRange(0, maxPayload);
    }
  }
  if (buffer.isNotEmpty) yield List<int>.of(buffer);
}

/// Transfers a firmware image to a device that is already running its
/// Updater over Classic Bluetooth SPP.
///
/// This is intentionally separate from [RecoveryOta]: the normal OTA flow
/// starts on the BLE Main service and waits for the device to reboot, while
/// rescue mode starts directly at the SPP Updater handshake.
class SppRecoveryOta {
  SppRecoveryOta({
    required this.connectSpp,
    this.sppReconnectTimeout = const Duration(seconds: 30),
    this.sppRetryDelay = const Duration(milliseconds: 250),
    this.stateTimeout = const Duration(seconds: 15),
    this.startAckTimeout = const Duration(seconds: 3),
    this.ackTimeout = const Duration(seconds: 5),
    this.frameDelay = const Duration(milliseconds: 10),
    this.finishTimeout = const Duration(seconds: 60),
    this.onState,
    this.onProgress,
    this.log,
  });

  final SppConnector connectSpp;
  final Duration sppReconnectTimeout;
  final Duration sppRetryDelay;
  final Duration stateTimeout;

  /// Maximum time to wait for the optional `receiving` status after START.
  ///
  /// SPP is an ordered byte stream. If the START write completed and the
  /// connection is still alive, withholding all data indefinitely because the
  /// informational status line was lost can deadlock a valid update session.
  final Duration startAckTimeout;

  /// Maximum time to wait for the ACK of each OTAD payload.
  final Duration ackTimeout;

  /// Delay between consecutive OTAD frame writes.
  final Duration frameDelay;
  final Duration finishTimeout;
  final void Function(Map<String, dynamic>)? onState;
  final void Function(double)? onProgress;
  final void Function(String)? log;

  String _phase = 'starting';
  Map<String, dynamic>? _lastState;
  Object? _error;
  bool _success = false;

  void _emit(String phase) {
    _phase = phase;
    log?.call('OTA phase=$phase');
    onState?.call({'state': phase});
  }

  void _handleState(Map<String, dynamic> state) {
    _lastState = state;
    log?.call('OTA status=$state');
    final name = state['state']?.toString();
    if (name == 'error' || name == 'aborted') {
      final code = state['code']?.toString() ?? 'unknown';
      _error = StateError('${otaErrorLabel(code)} ($code)');
    } else if (name == 'success' && _phase == 'verifying') {
      _success = true;
    }
    onState?.call(state);
  }

  Future<void> _wait(bool Function() condition, Duration timeout) async {
    final watch = Stopwatch()..start();
    while (!condition()) {
      if (_error != null) throw _error!;
      if (watch.elapsed >= timeout) {
        throw TimeoutException('OTA ${otaStateLabel(_phase)}超时', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (_error != null) throw _error!;
  }

  Future<SppOtaTransport> _connectSppWithRetry() async {
    final watch = Stopwatch()..start();
    Object? lastError;
    StackTrace? lastStack;
    var delay = sppRetryDelay;

    while (true) {
      final remaining = sppReconnectTimeout - watch.elapsed;
      if (remaining <= Duration.zero) break;

      log?.call(
        'SPP rescue connect attempt; remaining=${remaining.inMilliseconds}ms',
      );
      Future<SppOtaTransport>? attempt;
      try {
        attempt = connectSpp();
        return await attempt.timeout(remaining);
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        log?.call('SPP rescue connect attempt failed: $error');
        if (error is TimeoutException && attempt != null) {
          unawaited(
            attempt.then<void>((transport) async {
              try {
                await transport.close();
              } catch (_) {}
            }, onError: (_, _) {}),
          );
        }
      }

      final afterAttempt = sppReconnectTimeout - watch.elapsed;
      if (afterAttempt <= Duration.zero) break;
      final wait = delay < afterAttempt ? delay : afterAttempt;
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      delay = Duration(milliseconds: min(delay.inMilliseconds * 2, 2000));
    }

    final error =
        lastError ?? TimeoutException('SPP 连接超时', sppReconnectTimeout);
    Error.throwWithStackTrace(error, lastStack ?? StackTrace.current);
  }

  Future<void> run(Stream<List<int>> firmware, int total, String sha256) async {
    if (total <= 0) throw ArgumentError('固件文件为空');
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      throw ArgumentError('SHA-256 格式无效');
    }

    final start = 'OTA_START $total $sha256';
    SppOtaTransport? spp;
    StreamSubscription<Map<String, dynamic>>? sppStates;
    StreamSubscription<void>? sppDisconnect;
    final terminalError = Completer<Object>();
    final pendingAcks = <int>[];
    var remoteFailure = false;

    void fail(Object error) {
      _error ??= error;
      if (!terminalError.isCompleted) terminalError.complete(error);
    }

    void handleSppState(Map<String, dynamic> state) {
      _handleState(state);
      if (_error != null) {
        remoteFailure = true;
        fail(_error!);
        return;
      }
      if (state['state'] == 'ack') {
        final received = _jsonInt(state['received']);
        final ackTotal = _jsonInt(state['total']);
        if (received == null || ackTotal == null || ackTotal != total) {
          remoteFailure = true;
          fail(
            StateError(
              'Updater SPP ACK 字段无效：received=${state['received']} '
              'total=${state['total']}，期待 total=$total',
            ),
          );
          return;
        }
        pendingAcks.add(received);
      }
    }

    try {
      _lastState = null;
      _error = null;
      _success = false;
      _emit('reconnecting');
      spp = await _connectSppWithRetry();
      sppStates = spp.states.listen(handleSppState);
      sppDisconnect = spp.disconnected.listen((_) {
        if (!_success) fail(StateError(otaErrorLabel('disconnected')));
      });
      await spp.ready.timeout(stateTimeout);

      _lastState = null;
      _emit('receiving');
      await _raceSppOperation(spp.control(start), terminalError.future);
      final receivingAckWatch = Stopwatch()..start();
      while (_lastState?['state'] != 'receiving') {
        if (_error != null) throw _error!;
        if (!spp.connected) {
          throw StateError(otaErrorLabel('disconnected'));
        }
        if (receivingAckWatch.elapsed >= startAckTimeout) {
          log?.call(
            'SPP did not report receiving; proceeding with ordered data stream',
          );
          break;
        }
        await _raceSppOperation(
          Future<void>.delayed(const Duration(milliseconds: 20)),
          terminalError.future,
        );
      }
      if (_error != null) throw _error!;

      var sent = 0;
      onProgress?.call(0);
      final payloadSize = min(spp.maxPayload, maxOtaSppPayload);
      if (payloadSize <= 0) throw StateError('SPP 数据包大小无效');
      await for (final payload in _fixedSppPayloads(firmware, payloadSize)) {
        if (_error != null) throw _error!;
        if (sent + payload.length > total) {
          throw StateError('固件文件在传输时发生变化');
        }
        await _raceSppOperation(
          spp.write(otaSppFrame(payload)),
          terminalError.future,
        );
        sent += payload.length;
        await _waitForSppAck(
          pendingAcks: pendingAcks,
          expectedReceived: sent,
          timeout: ackTimeout,
          terminalError: terminalError.future,
        );
        onProgress?.call(sent / total);
        if (frameDelay > Duration.zero) {
          await _raceSppOperation(
            Future<void>.delayed(frameDelay),
            terminalError.future,
          );
        }
      }
      if (_error != null) throw _error!;
      if (sent != total) throw StateError('固件文件读取不完整');
      log?.call('SPP rescue wrote $sent/$total payload bytes');

      _emit('verifying');
      if (_error != null) throw _error!;
      await _raceSppOperation(spp.control('FINISH'), terminalError.future);
      await _wait(() => _success, finishTimeout);
      _emit('success');
    } catch (error) {
      final ackTimedOut = error is SppAckTimeoutException;
      if (ackTimedOut && spp?.connected == true) {
        log?.call(
          'SPP ACK timeout at received=${error.expectedReceived}; '
          'closing session so OTA can restart from the beginning',
        );
        try {
          await spp!.close();
        } catch (_) {}
      }
      if (spp?.connected == true &&
          !_success &&
          !remoteFailure &&
          !ackTimedOut &&
          (_phase == 'receiving' || _phase == 'verifying')) {
        try {
          await spp!.control('CANCEL');
        } catch (_) {}
      }
      rethrow;
    } finally {
      await sppStates?.cancel();
      await sppDisconnect?.cancel();
      await spp?.close();
    }
  }
}

/// Main BLE start -> expected reboot -> Classic SPP Updater -> transfer.
class RecoveryOta {
  RecoveryOta(
    this.mainTransport, {
    required this.connectSpp,
    this.handoffTimeout = const Duration(seconds: 15),
    this.sppReconnectTimeout = const Duration(seconds: 30),
    this.sppRetryDelay = const Duration(milliseconds: 250),
    this.stateTimeout = const Duration(seconds: 15),
    this.startAckTimeout = const Duration(seconds: 3),
    this.ackTimeout = const Duration(seconds: 5),
    this.frameDelay = const Duration(milliseconds: 10),
    this.finishTimeout = const Duration(seconds: 60),
    this.onState,
    this.onProgress,
    this.log,
  });

  final MainOtaTransport mainTransport;
  final SppConnector connectSpp;
  final Duration handoffTimeout;
  final Duration sppReconnectTimeout;
  final Duration sppRetryDelay;
  final Duration stateTimeout;

  /// Maximum time to wait for the optional `receiving` status after START.
  /// The START command and subsequent SPP frames are ordered, so a missing
  /// informational status must not prevent the actual transfer indefinitely.
  final Duration startAckTimeout;

  /// Maximum time to wait for the ACK of each OTAD payload.
  final Duration ackTimeout;

  /// Delay between consecutive OTAD frame writes.
  final Duration frameDelay;
  final Duration finishTimeout;
  final void Function(Map<String, dynamic>)? onState;
  final void Function(double)? onProgress;
  final void Function(String)? log;

  String _phase = 'starting';
  Map<String, dynamic>? _lastState;
  Object? _error;
  bool _success = false;

  void _emit(String phase) {
    _phase = phase;
    log?.call('OTA phase=$phase');
    onState?.call({'state': phase});
  }

  void _handleState(Map<String, dynamic> state, {required bool forward}) {
    _lastState = state;
    log?.call('OTA status=$state');
    final name = state['state']?.toString();
    if (name == 'error' || name == 'aborted') {
      final code = state['code']?.toString() ?? 'unknown';
      _error = StateError('${otaErrorLabel(code)} ($code)');
    } else if (name == 'success' && _phase == 'verifying') {
      _success = true;
    }
    if (forward) onState?.call(state);
  }

  Future<void> _wait(bool Function() condition, Duration timeout) async {
    final watch = Stopwatch()..start();
    while (!condition()) {
      if (_error != null) throw _error!;
      if (watch.elapsed >= timeout) {
        throw TimeoutException('OTA ${otaStateLabel(_phase)}超时', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (_error != null) throw _error!;
  }

  Future<SppOtaTransport> _connectSppWithRetry() async {
    final watch = Stopwatch()..start();
    Object? lastError;
    StackTrace? lastStack;
    var delay = sppRetryDelay;

    while (true) {
      final remaining = sppReconnectTimeout - watch.elapsed;
      if (remaining <= Duration.zero) break;

      log?.call('SPP connect attempt; remaining=${remaining.inMilliseconds}ms');
      Future<SppOtaTransport>? attempt;
      try {
        attempt = connectSpp();
        return await attempt.timeout(remaining);
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        log?.call('SPP connect attempt failed: $error');

        // A timed-out native attempt may complete later. Do not leave a
        // successful late connection alive when the retry loop has moved on.
        if (error is TimeoutException && attempt != null) {
          unawaited(
            attempt.then<void>((transport) async {
              try {
                await transport.close();
              } catch (_) {}
            }, onError: (_, _) {}),
          );
        }
      }

      final afterAttempt = sppReconnectTimeout - watch.elapsed;
      if (afterAttempt <= Duration.zero) break;
      final wait = delay < afterAttempt ? delay : afterAttempt;
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      final nextMilliseconds = min(delay.inMilliseconds * 2, 2000);
      delay = Duration(milliseconds: nextMilliseconds);
    }

    final error =
        lastError ?? TimeoutException('SPP 连接超时', sppReconnectTimeout);
    Error.throwWithStackTrace(error, lastStack ?? StackTrace.current);
  }

  Future<void> run(Stream<List<int>> firmware, int total, String sha256) async {
    if (total <= 0) throw ArgumentError('固件文件为空');
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      throw ArgumentError('SHA-256 格式无效');
    }
    final start = 'OTA_START $total $sha256';
    if (utf8.encode(start).length > mainTransport.maxControlPayload) {
      throw StateError('BLE MTU 不足以向 Main 发送完整 SHA-256，请重新连接');
    }

    var mainDisconnected = false;
    final mainStates = mainTransport.states.listen(
      (state) => _handleState(state, forward: false),
    );
    final mainConnections = mainTransport.connections.listen((connected) {
      if (!connected) {
        mainDisconnected = true;
        log?.call('Expected Main BLE disconnect for Updater reboot');
      }
    });
    SppOtaTransport? spp;
    StreamSubscription<Map<String, dynamic>>? sppStates;
    StreamSubscription<void>? sppDisconnect;
    final terminalError = Completer<Object>();
    final pendingAcks = <int>[];
    var remoteFailure = false;

    void fail(Object error) {
      _error ??= error;
      if (!terminalError.isCompleted) terminalError.complete(error);
    }

    void handleSppState(Map<String, dynamic> state) {
      _handleState(state, forward: true);
      if (_error != null) {
        remoteFailure = true;
        fail(_error!);
        return;
      }
      if (state['state'] == 'ack') {
        final received = _jsonInt(state['received']);
        final ackTotal = _jsonInt(state['total']);
        if (received == null || ackTotal == null || ackTotal != total) {
          remoteFailure = true;
          fail(
            StateError(
              'Updater SPP ACK 字段无效：received=${state['received']} '
              'total=${state['total']}，期待 total=$total',
            ),
          );
          return;
        }
        pendingAcks.add(received);
      }
    }

    try {
      _emit('starting');
      await mainTransport.control(start);
      await _wait(
        () => _lastState?['state'] == 'receiving' || mainDisconnected,
        stateTimeout,
      );
      _emit('switching');
      await _wait(() => mainDisconnected, handoffTimeout);
      await mainStates.cancel();
      await mainConnections.cancel();

      _lastState = null;
      _error = null;
      _emit('reconnecting');
      spp = await _connectSppWithRetry();
      sppStates = spp.states.listen(handleSppState);
      sppDisconnect = spp.disconnected.listen((_) {
        if (!_success) {
          fail(StateError(otaErrorLabel('disconnected')));
        }
      });
      await spp.ready.timeout(stateTimeout);

      _lastState = null;
      _emit('receiving');
      await _raceSppOperation(spp.control(start), terminalError.future);
      final receivingAckWatch = Stopwatch()..start();
      while (_lastState?['state'] != 'receiving') {
        if (_error != null) throw _error!;
        if (!spp.connected) {
          throw StateError(otaErrorLabel('disconnected'));
        }
        if (receivingAckWatch.elapsed >= startAckTimeout) {
          log?.call(
            'SPP did not report receiving; proceeding with ordered data stream',
          );
          break;
        }
        await _raceSppOperation(
          Future<void>.delayed(const Duration(milliseconds: 20)),
          terminalError.future,
        );
      }
      if (_error != null) throw _error!;

      var sent = 0;
      onProgress?.call(0);
      final payloadSize = min(spp.maxPayload, maxOtaSppPayload);
      if (payloadSize <= 0) throw StateError('SPP 数据包大小无效');
      await for (final payload in _fixedSppPayloads(firmware, payloadSize)) {
        if (_error != null) throw _error!;
        if (sent + payload.length > total) {
          throw StateError('固件文件在传输时发生变化');
        }
        await _raceSppOperation(
          spp.write(otaSppFrame(payload)),
          terminalError.future,
        );
        sent += payload.length;
        await _waitForSppAck(
          pendingAcks: pendingAcks,
          expectedReceived: sent,
          timeout: ackTimeout,
          terminalError: terminalError.future,
        );
        onProgress?.call(sent / total);
        if (frameDelay > Duration.zero) {
          await _raceSppOperation(
            Future<void>.delayed(frameDelay),
            terminalError.future,
          );
        }
      }
      if (_error != null) throw _error!;
      if (sent != total) throw StateError('固件文件读取不完整');
      log?.call('SPP wrote $sent/$total payload bytes');

      _emit('verifying');
      if (_error != null) throw _error!;
      await _raceSppOperation(spp.control('FINISH'), terminalError.future);
      await _wait(() => _success, finishTimeout);
      _emit('success');
    } catch (error) {
      final ackTimedOut = error is SppAckTimeoutException;
      if (ackTimedOut && spp?.connected == true) {
        log?.call(
          'SPP ACK timeout at received=${error.expectedReceived}; '
          'closing session so OTA can restart from the beginning',
        );
        try {
          await spp!.close();
        } catch (_) {}
      }
      if (spp?.connected == true &&
          !_success &&
          !remoteFailure &&
          !ackTimedOut &&
          (_phase == 'receiving' || _phase == 'verifying')) {
        try {
          await spp!.control('CANCEL');
        } catch (_) {}
      } else if (!mainDisconnected && mainTransport.connected) {
        try {
          await mainTransport.control('CANCEL');
        } catch (_) {}
      }
      rethrow;
    } finally {
      await mainStates.cancel();
      await mainConnections.cancel();
      await sppStates?.cancel();
      await sppDisconnect?.cancel();
      await spp?.close();
    }
  }
}
