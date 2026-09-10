import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lbjconsole/services/ble_protocol.dart';
import 'package:lbjconsole/services/recovery_ota.dart';
// Test our vendored dependency's wire framing directly.
// ignore: avoid_relative_lib_imports
import '../third_party/win_ble/lib/src/utils/ipc_decoder.dart';

class FakeMain implements MainOtaTransport {
  final status = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final connection = StreamController<bool>.broadcast(sync: true);
  final commands = <String>[];
  bool disconnectOnStart = true;
  @override
  bool connected = true;
  @override
  int maxControlPayload = 244;
  @override
  Stream<Map<String, dynamic>> get states => status.stream;
  @override
  Stream<bool> get connections => connection.stream;
  @override
  Future<void> control(String command) async {
    commands.add(command);
    if (command.startsWith('OTA_START')) {
      status.add({'state': 'receiving'});
      if (disconnectOnStart) {
        connected = false;
        connection.add(false);
      }
    }
  }

  Future<void> dispose() async {
    await status.close();
    await connection.close();
  }
}

class FakeSpp implements SppOtaTransport {
  final status = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final disconnect = StreamController<void>.broadcast(sync: true);
  final commands = <String>[];
  final frames = <List<int>>[];
  bool disconnectOnData = false;
  bool finishError = false;
  bool finishSilent = false;
  bool sendReceivingStatus = true;
  bool sendAck = true;
  bool wrongAck = false;
  bool errorOnFirstFrame = false;
  bool closed = false;
  int ackTotal = 0;
  int received = 0;
  @override
  bool connected = true;
  @override
  int maxPayload = 64;
  @override
  Stream<Map<String, dynamic>> get states => status.stream;
  @override
  Stream<void> get disconnected => disconnect.stream;
  @override
  Future<void> get ready => Future.value();
  @override
  Future<void> control(String command) async {
    commands.add(command);
    if (command.startsWith('OTA_START')) {
      final fields = command.split(' ');
      ackTotal = fields.length > 1 ? int.tryParse(fields[1]) ?? 0 : 0;
      received = 0;
      if (sendReceivingStatus) {
        status.add({'state': 'receiving', 'received': 0, 'total': ackTotal});
      }
    } else if (command == 'FINISH' && !finishSilent) {
      status.add({'state': 'verifying'});
      status.add(
        finishError
            ? {'state': 'error', 'code': 'sha256_mismatch'}
            : {'state': 'success'},
      );
      connected = false;
      disconnect.add(null);
    }
  }

  @override
  Future<void> write(List<int> frame) async {
    frames.add(frame);
    if (errorOnFirstFrame && frames.length == 1) {
      status.add({'state': 'error', 'code': 'queue_full'});
      // Keep the write pending briefly so the OTA runner must observe the
      // terminal status instead of winning a race with a completed write.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return;
    }
    if (sendAck) {
      received += frame.length - 12;
      final ackReceived = wrongAck ? received - 1 : received;
      status.add({
        'state': 'ack',
        'received': ackReceived,
        'total': ackTotal,
        'percent': ackTotal == 0 ? 0 : received * 100 ~/ ackTotal,
      });
    }
    if (disconnectOnData) {
      connected = false;
      disconnect.add(null);
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (connected) {
      connected = false;
      disconnect.add(null);
    }
  }

  Future<void> dispose() async {
    await status.close();
    await disconnect.close();
  }
}

void main() {
  final hash = 'ab' * 32;
  RecoveryOta runner(FakeMain main, FakeSpp spp) => RecoveryOta(
    main,
    connectSpp: () async => spp,
    handoffTimeout: const Duration(milliseconds: 60),
    stateTimeout: const Duration(milliseconds: 100),
    finishTimeout: const Duration(milliseconds: 100),
  );

  test(
    'First launch is manual; remembered MAC permits reconnect only when idle',
    () {
      bool policy(String? address, {bool blocked = false, bool ota = false}) =>
          shouldReconnectBle(
            savedAddress: address,
            adapterOn: true,
            connected: false,
            connecting: false,
            manuallyDisconnected: false,
            blocked: blocked,
            otaActive: ota,
          );
      expect(policy(null), isFalse);
      expect(policy(''), isFalse);
      expect(policy('44:1D:64:CE:26:E2'), isTrue);
      expect(policy('44:1D:64:CE:26:E2', blocked: true), isFalse);
      expect(policy('44:1D:64:CE:26:E2', ota: true), isFalse);
    },
  );

  test('SPP frame contains length, CRC32 and payload', () {
    final payload = utf8.encode('123456789');
    final frame = otaSppFrame(payload);
    expect(frame.take(4), utf8.encode('OTAD'));
    final header = ByteData.sublistView(frame);
    expect(header.getUint32(4, Endian.little), payload.length);
    expect(header.getUint32(8, Endian.little), 0xcbf43926);
    expect(frame.skip(12), payload);
  });

  test('SPP frame enforces the 4096-byte payload limit', () {
    expect(
      () => otaSppFrame(List<int>.filled(maxOtaSppPayload + 1, 0)),
      throwsArgumentError,
    );
  });

  test('SPP line decoder handles UTF8 fragmentation and CRLF', () {
    final decoder = SppLineDecoder();
    final lines = <String>[];
    for (final byte in utf8.encode('握手\r\n{"state":"idle"}\n')) {
      lines.addAll(decoder.add([byte]));
    }
    expect(lines, ['握手', '{"state":"idle"}']);
  });

  test('BLE JSON handles split UTF8, escaped quotes and braces', () {
    final decoder = BleJsonDecoder();
    final value = {'type': 'device_name', 'name': '中文{"\\设备'};
    final output = <Map<String, dynamic>>[];
    for (final byte in utf8.encode('LBJ Ready${jsonEncode(value)}')) {
      output.addAll(decoder.add([byte]));
    }
    expect(output, [value]);
  });

  test(
    'BLE JSON drops one malformed frame and keeps the rest of the batch',
    () {
      final decoder = BleJsonDecoder();
      expect(decoder.add(utf8.encode('{"ok":1}{bad}{"ok":2}')), [
        {'ok': 1},
        {'ok': 2},
      ]);
    },
  );

  test(
    'SPP line decoder drops invalid UTF8 without poisoning the next line',
    () {
      final decoder = SppLineDecoder();
      expect(
        decoder.add([0xff, 0xfe, 0x0a, ...utf8.encode('{"state":"idle"}\n')]),
        ['{"state":"idle"}'],
      );
    },
  );

  test('Windows IPC buffers headers and UTF8 across every boundary', () {
    final decoder = IpcDecoder();
    final expected = {'error': '蓝牙设备不可用', '_type': 'response', '_id': 7};
    final payload = utf8.encode(jsonEncode(expected));
    final header = ByteData(4)..setUint32(0, payload.length, Endian.little);
    final bytes = [...header.buffer.asUint8List(), ...payload];
    final output = <dynamic>[];
    for (final byte in bytes) {
      output.addAll(decoder.add([byte]));
    }
    expect(output, [expected]);
  });

  test(
    'Main BLE starts once, then SPP starts and carries framed data',
    () async {
      final main = FakeMain();
      final spp = FakeSpp();
      addTearDown(main.dispose);
      addTearDown(spp.dispose);
      final bytes = List.generate(150, (index) => index & 255);
      await runner(main, spp).run(Stream.value(bytes), bytes.length, hash);
      expect(main.commands.where((c) => c.startsWith('OTA_START')).length, 1);
      expect(spp.commands.first, main.commands.first);
      expect(spp.commands.last, 'FINISH');
      expect(spp.frames.every((frame) => frame.length <= 76), isTrue);
      expect(spp.frames.expand((frame) => frame.skip(12)), bytes);
      expect(spp.closed, isTrue);
    },
  );

  test('SPP connection retries while the updater is starting', () async {
    final main = FakeMain();
    final spp = FakeSpp();
    var attempts = 0;
    addTearDown(main.dispose);
    addTearDown(spp.dispose);
    final ota = RecoveryOta(
      main,
      connectSpp: () async {
        attempts++;
        if (attempts < 3) throw StateError('updater not ready');
        return spp;
      },
      handoffTimeout: const Duration(milliseconds: 60),
      sppReconnectTimeout: const Duration(milliseconds: 200),
      sppRetryDelay: const Duration(milliseconds: 1),
      stateTimeout: const Duration(milliseconds: 100),
      finishTimeout: const Duration(milliseconds: 100),
    );
    await ota.run(Stream.value([1]), 1, hash);
    expect(attempts, 3);
  });

  test('Rescue SPP starts directly without Main BLE', () async {
    final spp = FakeSpp();
    addTearDown(spp.dispose);
    final bytes = List.generate(90, (index) => index & 255);

    await SppRecoveryOta(
      connectSpp: () async => spp,
      stateTimeout: const Duration(milliseconds: 100),
      finishTimeout: const Duration(milliseconds: 100),
    ).run(Stream.value(bytes), bytes.length, hash);

    expect(spp.commands.first.startsWith('OTA_START'), isTrue);
    expect(spp.commands.last, 'FINISH');
    expect(spp.frames.expand((frame) => frame.skip(12)), bytes);
    expect(spp.closed, isTrue);
  });

  test(
    'SPP sends at most 4096 bytes and waits for each cumulative ACK',
    () async {
      final spp = FakeSpp()..maxPayload = 4096;
      addTearDown(spp.dispose);
      final bytes = List.generate(9000, (index) => index & 255);

      await SppRecoveryOta(
        connectSpp: () async => spp,
        finishTimeout: const Duration(milliseconds: 100),
        frameDelay: Duration.zero,
      ).run(Stream.value(bytes), bytes.length, hash);

      expect(spp.frames.map((frame) => frame.length - 12), [4096, 4096, 808]);
      expect(spp.received, bytes.length);
      expect(spp.commands.last, 'FINISH');
    },
  );

  test('SPP rejects an ACK that does not advance to the sent total', () async {
    final spp = FakeSpp()..wrongAck = true;
    addTearDown(spp.dispose);
    final bytes = List.generate(90, (index) => index & 255);

    await expectLater(
      SppRecoveryOta(
        connectSpp: () async => spp,
        frameDelay: Duration.zero,
      ).run(Stream.value(bytes), bytes.length, hash),
      throwsA(
        predicate<Object>((error) => error.toString().contains('received=')),
      ),
    );
    expect(spp.frames.length, 1);
    expect(spp.commands, isNot(contains('FINISH')));
  });

  test(
    'SPP ACK timeout closes the session without resending the block',
    () async {
      final spp = FakeSpp()..sendAck = false;
      addTearDown(spp.dispose);
      final bytes = List.generate(90, (index) => index & 255);

      await expectLater(
        SppRecoveryOta(
          connectSpp: () async => spp,
          ackTimeout: const Duration(milliseconds: 10),
          frameDelay: Duration.zero,
        ).run(Stream.value(bytes), bytes.length, hash),
        throwsA(isA<SppAckTimeoutException>()),
      );
      expect(spp.frames.length, 1);
      expect(spp.commands, isNot(contains('FINISH')));
      expect(spp.commands, isNot(contains('CANCEL')));
      expect(spp.closed, isTrue);
    },
  );

  test('SPP sends data when receiving status is not reported', () async {
    final spp = FakeSpp()..sendReceivingStatus = false;
    addTearDown(spp.dispose);
    final bytes = List.generate(90, (index) => index & 255);

    await SppRecoveryOta(
      connectSpp: () async => spp,
      startAckTimeout: const Duration(milliseconds: 10),
      finishTimeout: const Duration(milliseconds: 100),
    ).run(Stream.value(bytes), bytes.length, hash);

    expect(spp.commands.first.startsWith('OTA_START'), isTrue);
    expect(spp.commands.last, 'FINISH');
    expect(spp.frames.expand((frame) => frame.skip(12)), bytes);
    expect(spp.closed, isTrue);
  });

  test(
    'BLE to SPP recovery also sends data without receiving status',
    () async {
      final main = FakeMain();
      final spp = FakeSpp()..sendReceivingStatus = false;
      addTearDown(main.dispose);
      addTearDown(spp.dispose);
      final bytes = List.generate(90, (index) => index & 255);

      await RecoveryOta(
        main,
        connectSpp: () async => spp,
        handoffTimeout: const Duration(milliseconds: 60),
        startAckTimeout: const Duration(milliseconds: 10),
        finishTimeout: const Duration(milliseconds: 100),
      ).run(Stream.value(bytes), bytes.length, hash);

      expect(spp.commands.first.startsWith('OTA_START'), isTrue);
      expect(spp.commands.last, 'FINISH');
      expect(spp.frames.expand((frame) => frame.skip(12)), bytes);
      expect(spp.closed, isTrue);
    },
  );

  test(
    'SPP error status stops sending and preserves the device code',
    () async {
      final spp = FakeSpp()..errorOnFirstFrame = true;
      addTearDown(spp.dispose);
      final bytes = List.generate(4096, (index) => index & 255);

      await expectLater(
        SppRecoveryOta(
          connectSpp: () async => spp,
          startAckTimeout: const Duration(milliseconds: 10),
          frameDelay: Duration.zero,
        ).run(Stream.value(bytes), bytes.length, hash),
        throwsA(
          predicate<Object>((error) => error.toString().contains('queue_full')),
        ),
      );

      expect(spp.frames.length, 1);
      expect(spp.commands, isNot(contains('FINISH')));
      expect(spp.commands, isNot(contains('CANCEL')));
    },
  );

  test('Missing Main reboot never attempts SPP', () async {
    final main = FakeMain()..disconnectOnStart = false;
    final spp = FakeSpp();
    var connectedSpp = false;
    addTearDown(main.dispose);
    addTearDown(spp.dispose);
    final ota = RecoveryOta(
      main,
      connectSpp: () async {
        connectedSpp = true;
        return spp;
      },
      handoffTimeout: const Duration(milliseconds: 30),
      stateTimeout: const Duration(milliseconds: 60),
    );
    await expectLater(
      ota.run(Stream.value([1]), 1, hash),
      throwsA(isA<TimeoutException>()),
    );
    expect(connectedSpp, isFalse);
    expect(main.commands.last, 'CANCEL');
  });

  test('SPP disconnect aborts and never finishes', () async {
    final main = FakeMain();
    final spp = FakeSpp()..disconnectOnData = true;
    addTearDown(main.dispose);
    addTearDown(spp.dispose);
    await expectLater(
      runner(main, spp).run(Stream.value(List.filled(150, 0)), 150, hash),
      throwsStateError,
    );
    expect(spp.frames.length, 1);
    expect(spp.commands, isNot(contains('FINISH')));
  });

  test('SPP verification failure is surfaced', () async {
    final main = FakeMain();
    final spp = FakeSpp()..finishError = true;
    addTearDown(main.dispose);
    addTearDown(spp.dispose);
    await expectLater(
      runner(main, spp).run(Stream.value([1]), 1, hash),
      throwsStateError,
    );
  });

  test('Missing SPP success status times out', () async {
    final main = FakeMain();
    final spp = FakeSpp()..finishSilent = true;
    addTearDown(main.dispose);
    addTearDown(spp.dispose);
    await expectLater(
      runner(main, spp).run(Stream.value([1]), 1, hash),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('Small BLE MTU cannot silently omit SHA256', () async {
    final main = FakeMain()..maxControlPayload = 20;
    final spp = FakeSpp();
    addTearDown(main.dispose);
    addTearDown(spp.dispose);
    await expectLater(
      runner(main, spp).run(Stream.value([1]), 1, hash),
      throwsStateError,
    );
    expect(main.commands, isEmpty);
    expect(spp.commands, isEmpty);
  });
}
