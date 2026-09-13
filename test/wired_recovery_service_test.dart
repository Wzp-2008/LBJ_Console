import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lbjconsole/services/wired_recovery_service.dart';
import 'package:path/path.dart' as p;

void main() {
  test('exposes the supported recovery baud rates', () {
    expect(WiredRecoveryService.supportedBaudRates, [
      921600,
      460800,
      230400,
      115200,
      57600,
      38400,
      19200,
      9600,
    ]);
  });

  group('espflash output parsing', () {
    test('parses recognized COM ports and removes duplicates', () {
      final devices = WiredRecoveryService.parsePortListing('''
COM9  55D4:1A86  wch.cn  USB-Enhanced-SERIAL CH9102 (COM9)
COM10  303A:1001  Espressif  USB JTAG/serial
COM9  duplicate
COM1              Unknown type of port
''');

      expect(devices.map((device) => device.port), ['COM9', 'COM10']);
      expect(devices.first.vidPid, '55D4:1A86');
      expect(devices.first.vendor, 'wch.cn');
      expect(devices.first.description, contains('CH9102'));
    });

    test('ignores headers and returns empty list for no recognized ports', () {
      expect(
        WiredRecoveryService.parsePortListing(
          'List available serial ports.\nNo ports found.',
        ),
        isEmpty,
      );
    });

    test('surfaces a non-zero list-ports exit code', () async {
      final executor = _FakeExecutor(failAtCall: 0);
      await expectLater(
        WiredRecoveryService(executor: executor).scanDevices(),
        throwsA(isA<WiredRecoveryException>()),
      );
    });
  });

  group('firmware ZIP validation', () {
    test('loads the five root files and cross-checks CSV with BIN', () async {
      final root = await Directory.systemTemp.createTemp('wired-test-');
      addTearDown(() => root.delete(recursive: true));
      final zip = await _writeBundleZip(root);

      final bundle = await WiredRecoveryService().loadFirmwareZip(zip);
      addTearDown(bundle.dispose);

      expect(bundle.partitions['updater']!.offset, 0x20000);
      expect(bundle.partitions['firmware']!.size, 0x2F0000);
      expect(await bundle.file('bootloader.bin').length(), 8);
    });

    test('rejects the singular partition.csv spelling', () async {
      final root = await Directory.systemTemp.createTemp('wired-test-');
      addTearDown(() => root.delete(recursive: true));
      final zip = await _writeBundleZip(root, csvName: 'partition.csv');

      await expectLater(
        WiredRecoveryService().loadFirmwareZip(zip),
        throwsA(isA<WiredRecoveryException>()),
      );
    });

    test('rejects oversized images and overlapping partitions', () async {
      final root = await Directory.systemTemp.createTemp('wired-test-');
      addTearDown(() => root.delete(recursive: true));
      final oversized = await _writeBundleZip(
        root,
        bootloader: List<int>.filled(0xF001, 0),
      );
      await expectLater(
        WiredRecoveryService().loadFirmwareZip(oversized),
        throwsA(isA<WiredRecoveryException>()),
      );

      final overlap = await _writeBundleZip(
        root,
        csv: _csv(updaterOffset: 0x14000),
        binary: _partitionBinary(updaterOffset: 0x14000),
      );
      await expectLater(
        WiredRecoveryService().loadFirmwareZip(overlap),
        throwsA(isA<WiredRecoveryException>()),
      );
    });

    test('rejects a CSV/BIN offset mismatch', () async {
      final root = await Directory.systemTemp.createTemp('wired-test-');
      addTearDown(() => root.delete(recursive: true));
      final zip = await _writeBundleZip(
        root,
        binary: _partitionBinary(updaterOffset: 0x21000),
      );

      await expectLater(
        WiredRecoveryService().loadFirmwareZip(zip),
        throwsA(isA<WiredRecoveryException>()),
      );
    });

    test('rejects an image larger than its CSV partition', () async {
      final root = await Directory.systemTemp.createTemp('wired-test-');
      addTearDown(() => root.delete(recursive: true));
      final zip = await _writeBundleZip(
        root,
        csv: _csv(updaterSize: 16),
        binary: _partitionBinary(updaterSize: 16),
      );

      await expectLater(
        WiredRecoveryService().loadFirmwareZip(zip),
        throwsA(isA<WiredRecoveryException>()),
      );
    });
  });

  group('flash command sequence', () {
    test('uses the reference order and selected port/baud', () async {
      final root = await Directory.systemTemp.createTemp('wired-test-');
      addTearDown(() => root.delete(recursive: true));
      final bundle = await WiredRecoveryService().loadFirmwareZip(
        await _writeBundleZip(root),
      );
      addTearDown(bundle.dispose);
      final executor = _FakeExecutor();
      final service = WiredRecoveryService(
        executor: executor,
        executablePath: 'espflash.exe',
      );

      final events = <WiredFlashEvent>[];
      await service.flash(
        const EspflashDevice(port: 'COM9', description: 'test'),
        bundle,
        baud: 115200,
        onEvent: events.add,
      );

      expect(executor.calls.map((call) => call.first), [
        'board-info',
        'erase-region',
        'write-bin',
        'write-bin',
        'write-bin',
        'write-bin',
      ]);
      expect(
        executor.calls[1],
        containsAllInOrder(['--port', 'COM9', '--baud', '115200']),
      );
      expect(executor.calls[1], containsAllInOrder(['0x11000', '0x4000']));
      expect(
        executor.calls[2],
        containsAllInOrder([
          '--before',
          'no-reset',
          '--after',
          'no-reset',
          '0x1000',
        ]),
      );
      expect(executor.calls[3], contains('0x10000'));
      expect(executor.calls[4], contains('0x20000'));
      expect(
        executor.calls[5],
        containsAllInOrder(['--after', 'hard-reset', '0x110000']),
      );
      expect(
        executor.calls.every((call) => call.contains('--skip-update-check')),
        isTrue,
      );
      expect(events.last.completed, isTrue);
    });

    test('rejects a non-classic ESP32 before erasing', () async {
      final root = await Directory.systemTemp.createTemp('wired-test-');
      addTearDown(() => root.delete(recursive: true));
      final bundle = await WiredRecoveryService().loadFirmwareZip(
        await _writeBundleZip(root),
      );
      addTearDown(bundle.dispose);
      final executor = _FakeExecutor(boardOutput: 'Chip type: esp32c3');

      await expectLater(
        WiredRecoveryService(
          executor: executor,
          executablePath: 'espflash.exe',
        ).flash(
          const EspflashDevice(port: 'COM9', description: ''),
          bundle,
          baud: 921600,
        ),
        throwsA(isA<WiredRecoveryException>()),
      );
      expect(executor.calls, hasLength(1));
      expect(executor.calls.single.first, 'board-info');
    });

    test('stops immediately when a write command fails', () async {
      final root = await Directory.systemTemp.createTemp('wired-test-');
      addTearDown(() => root.delete(recursive: true));
      final bundle = await WiredRecoveryService().loadFirmwareZip(
        await _writeBundleZip(root),
      );
      addTearDown(bundle.dispose);
      final executor = _FakeExecutor(failAtCall: 4);

      await expectLater(
        WiredRecoveryService(
          executor: executor,
          executablePath: 'espflash.exe',
        ).flash(
          const EspflashDevice(port: 'COM9', description: ''),
          bundle,
          baud: 921600,
        ),
        throwsA(isA<WiredRecoveryException>()),
      );
      expect(executor.calls, hasLength(5));
    });
  });
}

class _FakeExecutor implements WiredProcessExecutor {
  _FakeExecutor({this.boardOutput = 'Chip type: ESP32', this.failAtCall});

  final String boardOutput;
  final int? failAtCall;
  final calls = <List<String>>[];

  @override
  Future<WiredProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    void Function(String line)? onOutput,
  }) async {
    calls.add(List.unmodifiable(arguments));
    final callNumber = calls.length - 1;
    final output = arguments.first == 'board-info' ? boardOutput : 'ok';
    onOutput?.call(output);
    return WiredProcessResult(
      exitCode: failAtCall == callNumber ? 1 : 0,
      output: output,
    );
  }
}

Future<File> _writeBundleZip(
  Directory root, {
  String csvName = 'partitions.csv',
  String? csv,
  Uint8List? binary,
  List<int>? bootloader,
}) async {
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes(
        'bootloader.bin',
        bootloader ?? List<int>.filled(8, 0xAA),
      ),
    )
    ..addFile(ArchiveFile.bytes('updater.bin', List<int>.filled(32, 0xBB)))
    ..addFile(ArchiveFile.bytes('firmware.bin', List<int>.filled(32, 0xCC)))
    ..addFile(ArchiveFile.bytes(csvName, (csv ?? _csv()).codeUnits))
    ..addFile(
      ArchiveFile.bytes('partitions.bin', binary ?? _partitionBinary()),
    );
  final file = File(p.join(root.path, 'firmware.zip'));
  await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
  return file;
}

String _csv({int updaterOffset = 0x20000, int updaterSize = 0xF0000}) =>
    '''
# Name, Type, SubType, Offset, Size, Flags
bootctl, data, 0x40, 0x11000, 0x4000,
updater, app, factory, ${_hex(updaterOffset)}, ${_hex(updaterSize)},
firmware, app, ota_0, 0x110000, 0x2F0000,
''';

Uint8List _partitionBinary({
  int updaterOffset = 0x20000,
  int updaterSize = 0xF0000,
}) {
  final bytes = Uint8List(0x1000)..fillRange(0, 0x1000, 0xFF);
  final entries = [
    ('bootctl', 0x11000, 0x4000),
    ('updater', updaterOffset, updaterSize),
    ('firmware', 0x110000, 0x2F0000),
  ];
  for (var index = 0; index < entries.length; index++) {
    final at = index * 32;
    final entry = entries[index];
    bytes[at] = 0xAA;
    bytes[at + 1] = 0x50;
    _writeU32(bytes, at + 4, entry.$2);
    _writeU32(bytes, at + 8, entry.$3);
    bytes.fillRange(at + 12, at + 28, 0);
    final label = entry.$1.codeUnits;
    bytes.setRange(at + 12, at + 12 + label.length, label);
  }
  final end = entries.length * 32;
  bytes[end] = 0xEB;
  bytes[end + 1] = 0xEB;
  return bytes;
}

void _writeU32(Uint8List bytes, int offset, int value) {
  bytes[offset] = value & 0xFF;
  bytes[offset + 1] = (value >> 8) & 0xFF;
  bytes[offset + 2] = (value >> 16) & 0xFF;
  bytes[offset + 3] = (value >> 24) & 0xFF;
}

String _hex(int value) => '0x${value.toRadixString(16)}';
