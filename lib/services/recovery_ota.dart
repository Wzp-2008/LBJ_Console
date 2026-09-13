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

void _emitOtaPhase(
  String phase, {
  required void Function(String)? log,
  required void Function(Map<String, dynamic>)? onState,
}) {
  log?.call('OTA phase=$phase');
  onState?.call({'state': phase});
}

StateError? _otaStateError(Map<String, dynamic> state) {
  final name = state['state']?.toString();
  if (name != 'error' && name != 'aborted') return null;
  final code = state['code']?.toString() ?? 'unknown';
  return StateError('${otaErrorLabel(code)} ($code)');
}

Future<void> _waitForOtaState({
  required bool Function() condition,
  required Duration timeout,
  required String phase,
  required Object? Function() error,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    final currentError = error();
    if (currentError != null) throw currentError;
    if (watch.elapsed >= timeout) {
      throw TimeoutException('OTA ${otaStateLabel(phase)}超时', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final currentError = error();
  if (currentError != null) throw currentError;
}

void _validateOtaPayload(int total, String sha256) {
  if (total <= 0) throw ArgumentError('固件文件为空');
  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
    throw ArgumentError('SHA-256 格式无效');
  }
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

/// Shared Classic SPP transfer state machine used by normal OTA and rescue
/// OTA. Their only difference is how the SPP session is reached; once the
/// Updater is connected, framing, ACK validation and cleanup are identical.
Future<void> _runSppTransfer({
  required SppConnector connectSpp,
  required Stream<List<int>> firmware,
  required int total,
  required String sha256,
  required Duration reconnectTimeout,
  required Duration retryDelay,
  required Duration stateTimeout,
  required Duration startAckTimeout,
  required Duration ackTimeout,
  required Duration frameDelay,
  required Duration finishTimeout,
  void Function(Map<String, dynamic>)? onState,
  void Function(double)? onProgress,
  void Function(String)? log,
}) async {
  var phase = 'starting';
  Map<String, dynamic>? lastState;
  Object? error;
  var success = false;
  final pendingAcks = <int>[];
  final terminalError = Completer<Object>();
  var remoteFailure = false;

  void emit(String value) {
    phase = value;
    _emitOtaPhase(value, log: log, onState: onState);
  }

  void fail(Object value) {
    error ??= value;
    if (!terminalError.isCompleted) terminalError.complete(value);
  }

  void handleState(Map<String, dynamic> state) {
    lastState = state;
    log?.call('OTA status=$state');
    final stateError = _otaStateError(state);
    if (stateError != null) {
      error = stateError;
      remoteFailure = true;
      fail(error!);
    } else if (state['state']?.toString() == 'success' &&
        phase == 'verifying') {
      success = true;
    }
    if (state['state']?.toString() == 'ack') {
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
      } else {
        pendingAcks.add(received);
      }
    }
    onState?.call(state);
  }

  Future<void> waitFor(bool Function() condition, Duration timeout) async {
    await _waitForOtaState(
      condition: condition,
      timeout: timeout,
      phase: phase,
      error: () => error,
    );
  }

  Future<SppOtaTransport> connectWithRetry() async {
    final watch = Stopwatch()..start();
    Object? lastError;
    StackTrace? lastStack;
    var delay = retryDelay;
    while (true) {
      final remaining = reconnectTimeout - watch.elapsed;
      if (remaining <= Duration.zero) break;
      Future<SppOtaTransport>? attempt;
      try {
        attempt = connectSpp();
        return await attempt.timeout(remaining);
      } catch (value, stack) {
        lastError = value;
        lastStack = stack;
        log?.call('SPP connect attempt failed: $value');
        if (value is TimeoutException && attempt != null) {
          unawaited(
            attempt.then<void>((transport) async {
              try {
                await transport.close();
              } catch (_) {}
            }, onError: (_, _) {}),
          );
        }
      }
      final afterAttempt = reconnectTimeout - watch.elapsed;
      if (afterAttempt <= Duration.zero) break;
      final wait = delay < afterAttempt ? delay : afterAttempt;
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      delay = Duration(milliseconds: min(delay.inMilliseconds * 2, 2000));
    }
    final finalError =
        lastError ?? TimeoutException('SPP 连接超时', reconnectTimeout);
    Error.throwWithStackTrace(finalError, lastStack ?? StackTrace.current);
  }

  SppOtaTransport? spp;
  StreamSubscription<Map<String, dynamic>>? stateSubscription;
  StreamSubscription<void>? disconnectSubscription;
  try {
    emit('reconnecting');
    spp = await connectWithRetry();
    stateSubscription = spp.states.listen(handleState);
    disconnectSubscription = spp.disconnected.listen((_) {
      if (!success) fail(StateError(otaErrorLabel('disconnected')));
    });
    await spp.ready.timeout(stateTimeout);

    lastState = null;
    emit('receiving');
    await _raceSppOperation(
      spp.control('OTA_START $total $sha256'),
      terminalError.future,
    );
    final receivingWatch = Stopwatch()..start();
    while (lastState?['state'] != 'receiving') {
      if (error != null) throw error!;
      if (!spp.connected) throw StateError(otaErrorLabel('disconnected'));
      if (receivingWatch.elapsed >= startAckTimeout) {
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
    if (error != null) throw error!;

    var sent = 0;
    onProgress?.call(0);
    final payloadSize = min(spp.maxPayload, maxOtaSppPayload);
    if (payloadSize <= 0) throw StateError('SPP 数据包大小无效');
    await for (final payload in _fixedSppPayloads(firmware, payloadSize)) {
      if (error != null) throw error!;
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
    if (error != null) throw error!;
    if (sent != total) throw StateError('固件文件读取不完整');

    emit('verifying');
    await _raceSppOperation(spp.control('FINISH'), terminalError.future);
    await waitFor(() => success, finishTimeout);
    emit('success');
  } catch (value) {
    final ackTimedOut = value is SppAckTimeoutException;
    if (ackTimedOut && spp?.connected == true) {
      try {
        await spp!.close();
      } catch (_) {}
    }
    if (spp?.connected == true &&
        !success &&
        !remoteFailure &&
        !ackTimedOut &&
        (phase == 'receiving' || phase == 'verifying')) {
      try {
        await spp!.control('CANCEL');
      } catch (_) {}
    }
    rethrow;
  } finally {
    await stateSubscription?.cancel();
    await disconnectSubscription?.cancel();
    await spp?.close();
  }
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

  Future<void> run(Stream<List<int>> firmware, int total, String sha256) async {
    _validateOtaPayload(total, sha256);
    return _runSppTransfer(
      connectSpp: connectSpp,
      firmware: firmware,
      total: total,
      sha256: sha256,
      reconnectTimeout: sppReconnectTimeout,
      retryDelay: sppRetryDelay,
      stateTimeout: stateTimeout,
      startAckTimeout: startAckTimeout,
      ackTimeout: ackTimeout,
      frameDelay: frameDelay,
      finishTimeout: finishTimeout,
      onState: onState,
      onProgress: onProgress,
      log: log,
    );
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

  void _emit(String phase) {
    _phase = phase;
    _emitOtaPhase(phase, log: log, onState: onState);
  }

  void _handleState(Map<String, dynamic> state) {
    _lastState = state;
    log?.call('OTA status=$state');
    _error = _otaStateError(state);
  }

  Future<void> run(Stream<List<int>> firmware, int total, String sha256) async {
    _validateOtaPayload(total, sha256);
    final start = 'OTA_START $total $sha256';
    if (utf8.encode(start).length > mainTransport.maxControlPayload) {
      throw StateError('BLE MTU 不足以向 Main 发送完整 SHA-256，请重新连接');
    }

    var mainDisconnected = false;
    final mainStates = mainTransport.states.listen(_handleState);
    final mainConnections = mainTransport.connections.listen((connected) {
      if (!connected) {
        mainDisconnected = true;
        log?.call('Expected Main BLE disconnect for Updater reboot');
      }
    });
    try {
      _emit('starting');
      await mainTransport.control(start);
      await _waitForOtaState(
        condition: () =>
            _lastState?['state'] == 'receiving' || mainDisconnected,
        timeout: stateTimeout,
        phase: _phase,
        error: () => _error,
      );
      _emit('switching');
      await _waitForOtaState(
        condition: () => mainDisconnected,
        timeout: handoffTimeout,
        phase: _phase,
        error: () => _error,
      );
      await mainStates.cancel();
      await mainConnections.cancel();

      await _runSppTransfer(
        connectSpp: connectSpp,
        firmware: firmware,
        total: total,
        sha256: sha256,
        reconnectTimeout: sppReconnectTimeout,
        retryDelay: sppRetryDelay,
        stateTimeout: stateTimeout,
        startAckTimeout: startAckTimeout,
        ackTimeout: ackTimeout,
        frameDelay: frameDelay,
        finishTimeout: finishTimeout,
        onState: onState,
        onProgress: onProgress,
        log: log,
      );
    } catch (error) {
      if (!mainDisconnected && mainTransport.connected) {
        try {
          await mainTransport.control('CANCEL');
        } catch (_) {}
      }
      rethrow;
    } finally {
      await mainStates.cancel();
      await mainConnections.cancel();
    }
  }
}
