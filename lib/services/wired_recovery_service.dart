import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// The stages exposed to the wired recovery progress dialog.
enum WiredFlashStage {
  validatingDevice,
  erasingBootctl,
  writingBootloader,
  writingPartitionTable,
  writingUpdater,
  writingFirmware,
}

extension WiredFlashStageLabel on WiredFlashStage {
  String get label {
    switch (this) {
      case WiredFlashStage.validatingDevice:
        return '校验设备';
      case WiredFlashStage.erasingBootctl:
        return '清除 bootctl';
      case WiredFlashStage.writingBootloader:
        return '写入 bootloader';
      case WiredFlashStage.writingPartitionTable:
        return '写入分区表';
      case WiredFlashStage.writingUpdater:
        return '写入 updater';
      case WiredFlashStage.writingFirmware:
        return '写入 firmware';
    }
  }
}

class EspflashDevice {
  const EspflashDevice({
    required this.port,
    required this.description,
    this.vidPid = '',
    this.vendor = '',
  });

  final String port;
  final String vidPid;
  final String vendor;
  final String description;

  String get details => [
    vidPid,
    vendor,
    description,
  ].where((value) => value.trim().isNotEmpty).join(' ');

  @override
  String toString() => '$port $details'.trim();
}

class WiredPartitionEntry {
  const WiredPartitionEntry({
    required this.name,
    required this.type,
    required this.subtype,
    required this.offset,
    required this.size,
  });

  final String name;
  final String type;
  final String subtype;
  final int offset;
  final int size;
}

class WiredFirmwareBundle {
  const WiredFirmwareBundle({
    required this.directory,
    required this.files,
    required this.partitions,
  });

  final Directory directory;
  final Map<String, File> files;
  final Map<String, WiredPartitionEntry> partitions;

  File file(String name) => files[name]!;

  Future<void> dispose() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

class WiredFlashEvent {
  const WiredFlashEvent({
    required this.stage,
    required this.message,
    this.output,
    this.completed = false,
  });

  final WiredFlashStage stage;
  final String message;
  final String? output;
  final bool completed;
}

class WiredRecoveryException implements Exception {
  WiredRecoveryException(this.message, {this.stage, this.output = ''});

  final String message;
  final WiredFlashStage? stage;
  final String output;

  @override
  String toString() => message;
}

class WiredProcessResult {
  const WiredProcessResult({required this.exitCode, required this.output});

  final int exitCode;
  final String output;
}

abstract class WiredProcessExecutor {
  Future<WiredProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    void Function(String line)? onOutput,
  });
}

/// The production process runner. Arguments are passed directly to espflash;
/// no shell interpolation is used for ports or paths selected by the user.
class IoWiredProcessExecutor implements WiredProcessExecutor {
  const IoWiredProcessExecutor();

  @override
  Future<WiredProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    void Function(String line)? onOutput,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
      environment: {
        ...Platform.environment,
        'ESPFLASH_SKIP_UPDATE_CHECK': 'true',
        'NO_COLOR': '1',
      },
    );

    final output = StringBuffer();

    Future<void> consume(Stream<List<int>> stream) async {
      await for (final line
          in stream
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())) {
        output.writeln(line);
        onOutput?.call(line);
      }
    }

    await Future.wait([consume(process.stdout), consume(process.stderr)]);
    return WiredProcessResult(
      exitCode: await process.exitCode,
      output: output.toString(),
    );
  }
}

class WiredRecoveryService {
  WiredRecoveryService({WiredProcessExecutor? executor, String? executablePath})
    : _executor = executor ?? const IoWiredProcessExecutor(),
      _executablePath = executablePath;

  static const supportedBaudRates = <int>[
    921600,
    460800,
    230400,
    115200,
    57600,
    38400,
    19200,
    9600,
  ];

  static const _expectedFiles = <String>{
    'bootloader.bin',
    'updater.bin',
    'firmware.bin',
    'partitions.csv',
    'partitions.bin',
  };
  static const _flashSize = 0x400000;
  static const _partitionTableOffset = 0x10000;
  static const _partitionTableSize = 0x1000;
  static const _bootloaderOffset = 0x1000;
  static const _bootloaderLimit = 0x10000;

  final WiredProcessExecutor _executor;
  final String? _executablePath;

  bool get isSupported => Platform.isWindows;

  Future<List<EspflashDevice>> scanDevices() async {
    final result = await _run([
      'list-ports',
      '--skip-update-check',
    ], workingDirectory: Directory.systemTemp.path);
    if (result.exitCode != 0) {
      throw WiredRecoveryException(
        'espflash 扫描设备失败（退出码 ${result.exitCode}）',
        output: result.output,
      );
    }
    return parsePortListing(result.output);
  }

  /// Parses the stable v4.5 list-ports table without treating arbitrary COM
  /// ports as ESP devices.
  static List<EspflashDevice> parsePortListing(String output) {
    final devices = <EspflashDevice>[];
    final seen = <String>{};
    final ansi = RegExp(r'\x1b\[[0-9;]*m');
    for (final rawLine in output.split(RegExp(r'\r?\n'))) {
      final line = rawLine.replaceAll(ansi, '').trim();
      final match = RegExp(
        r'^(COM\d+)\s*(.*)$',
        caseSensitive: false,
      ).firstMatch(line);
      if (match == null) continue;
      final port = match.group(1)!.toUpperCase();
      var details = match.group(2)?.trim() ?? '';
      // `list-ports` normally omits these, but keeping the parser defensive
      // prevents a manually supplied --list-all-ports-style line from
      // becoming a selectable ESP development board.
      if (details.toLowerCase().contains('unknown type of port')) continue;
      if (!seen.add(port)) continue;
      var vidPid = '';
      var vendor = '';
      final vidMatch = RegExp(
        r'^([0-9a-f]{4}:[0-9a-f]{4})\b\s*',
        caseSensitive: false,
      ).firstMatch(details);
      if (vidMatch != null) {
        vidPid = vidMatch.group(1)!.toUpperCase();
        details = details.substring(vidMatch.end).trim();
        final vendorMatch = RegExp(r'^(\S+)\s*').firstMatch(details);
        if (vendorMatch != null) {
          vendor = vendorMatch.group(1)!;
          details = details.substring(vendorMatch.end).trim();
        }
      }
      devices.add(
        EspflashDevice(
          port: port,
          vidPid: vidPid,
          vendor: vendor,
          description: details,
        ),
      );
    }
    return devices;
  }

  Future<WiredFirmwareBundle> loadFirmwareZip(File zipFile) async {
    if (!await zipFile.exists()) {
      throw WiredRecoveryException('固件 ZIP 文件不存在');
    }
    if (!zipFile.path.toLowerCase().endsWith('.zip')) {
      throw WiredRecoveryException('请选择 .zip 固件包');
    }

    late final Archive archive;
    late final ZipDecoder decoder;
    try {
      final bytes = await zipFile.readAsBytes();
      decoder = ZipDecoder();
      archive = decoder.decodeBytes(bytes, verify: true);
    } catch (error) {
      throw WiredRecoveryException('固件 ZIP 无法读取：$error');
    }

    final rawNames = decoder.directory.fileHeaders
        .map((header) => header.file?.filename ?? '')
        .toList();
    if (rawNames.length != _expectedFiles.length ||
        rawNames.toSet().length != rawNames.length ||
        archive.length != _expectedFiles.length ||
        archive.map((entry) => entry.name).toSet().length !=
            _expectedFiles.length ||
        !archive
            .map((entry) => entry.name)
            .toSet()
            .containsAll(_expectedFiles)) {
      throw WiredRecoveryException(
        '固件包必须在根目录严格包含五个文件：${_expectedFiles.join('、')}',
      );
    }

    final limits = <String, int>{
      'bootloader.bin': _bootloaderLimit - _bootloaderOffset,
      'updater.bin': 0xF0000,
      'firmware.bin': 0x2F0000,
      'partitions.csv': 64 * 1024,
      'partitions.bin': _partitionTableSize,
    };
    final entries = <String, ArchiveFile>{};
    for (final entry in archive) {
      if (!_expectedFiles.contains(entry.name) ||
          !entry.isFile ||
          entry.isSymbolicLink ||
          entry.name.contains('/') ||
          entry.name.contains('\\')) {
        throw WiredRecoveryException('固件包包含非法或嵌套文件：${entry.name}');
      }
      final limit = limits[entry.name]!;
      if (entry.size <= 0 || entry.size > limit) {
        throw WiredRecoveryException(
          '${entry.name} 大小为 ${entry.size} 字节，必须大于 0 且不超过 $limit 字节',
        );
      }
      entries[entry.name] = entry;
    }

    late final Map<String, WiredPartitionEntry> partitions;
    try {
      final csvText = utf8.decode(
        entries['partitions.csv']!.content,
        allowMalformed: false,
      );
      partitions = _parsePartitions(csvText);
      final binaryPartitions = _parseBinaryPartitions(
        entries['partitions.bin']!.content,
      );
      _verifyPartitionTables(partitions, binaryPartitions);
      for (final image in const ['updater.bin', 'firmware.bin']) {
        final partitionName = image.substring(0, image.length - 4);
        final partition = partitions[partitionName]!;
        if (entries[image]!.size > partition.size) {
          throw WiredRecoveryException(
            '$image 大小超过 $partitionName 分区容量 ${partition.size} 字节',
          );
        }
      }
    } catch (error) {
      if (error is WiredRecoveryException) rethrow;
      throw WiredRecoveryException('固件包内容无效：$error');
    }

    Directory? directory;
    try {
      directory = await Directory.systemTemp.createTemp('lbjconsole-wired-');
      final files = <String, File>{};
      for (final name in _expectedFiles) {
        final file = File(p.join(directory.path, name));
        await file.writeAsBytes(entries[name]!.content, flush: true);
        files[name] = file;
      }
      return WiredFirmwareBundle(
        directory: directory,
        files: Map.unmodifiable(files),
        partitions: Map.unmodifiable(partitions),
      );
    } catch (error) {
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
      if (error is WiredRecoveryException) rethrow;
      throw WiredRecoveryException('固件包解压失败：$error');
    }
  }

  Future<void> flash(
    EspflashDevice device,
    WiredFirmwareBundle bundle, {
    required int baud,
    void Function(WiredFlashEvent event)? onEvent,
  }) async {
    if (!supportedBaudRates.contains(baud)) {
      throw WiredRecoveryException('不支持的波特率：$baud');
    }
    final bootctl = bundle.partitions['bootctl'];
    final updater = bundle.partitions['updater'];
    final firmware = bundle.partitions['firmware'];
    if (bootctl == null || updater == null || firmware == null) {
      throw WiredRecoveryException('分区表缺少 bootctl、updater 或 firmware 分区');
    }

    final common = <String>[
      '--port',
      device.port,
      '--baud',
      '$baud',
      '--non-interactive',
      '--skip-update-check',
    ];

    final boardInfo = await _runStage(
      WiredFlashStage.validatingDevice,
      '正在识别设备…',
      ['board-info', ...common, '--after', 'hard-reset'],
      onEvent,
      workingDirectory: bundle.directory.path,
    );
    final boardOutput = boardInfo.output.replaceAll(
      RegExp(r'\x1b\[[0-9;]*m'),
      '',
    );
    if (!RegExp(
      r'^\s*Chip type:\s*esp32(?:\s|\(|$)',
      caseSensitive: false,
      multiLine: true,
    ).hasMatch(boardOutput)) {
      throw WiredRecoveryException(
        '所选设备不是经典 ESP32，已停止刷写',
        stage: WiredFlashStage.validatingDevice,
        output: boardOutput,
      );
    }

    await _runStage(
      WiredFlashStage.erasingBootctl,
      '正在清除 bootctl…',
      [
        'erase-region',
        '--chip',
        'esp32',
        ...common,
        '--after',
        'no-reset',
        _hex(bootctl.offset),
        _hex(bootctl.size),
      ],
      onEvent,
      workingDirectory: bundle.directory.path,
    );
    await _runStage(
      WiredFlashStage.writingBootloader,
      '正在写入 bootloader…',
      [
        'write-bin',
        '--chip',
        'esp32',
        ...common,
        '--before',
        'no-reset',
        '--after',
        'no-reset',
        _hex(_bootloaderOffset),
        bundle.file('bootloader.bin').path,
      ],
      onEvent,
      workingDirectory: bundle.directory.path,
    );
    await _runStage(
      WiredFlashStage.writingPartitionTable,
      '正在写入分区表…',
      [
        'write-bin',
        '--chip',
        'esp32',
        ...common,
        '--before',
        'no-reset',
        '--after',
        'no-reset',
        _hex(_partitionTableOffset),
        bundle.file('partitions.bin').path,
      ],
      onEvent,
      workingDirectory: bundle.directory.path,
    );
    await _runStage(
      WiredFlashStage.writingUpdater,
      '正在写入 updater…',
      [
        'write-bin',
        '--chip',
        'esp32',
        ...common,
        '--before',
        'no-reset',
        '--after',
        'no-reset',
        _hex(updater.offset),
        bundle.file('updater.bin').path,
      ],
      onEvent,
      workingDirectory: bundle.directory.path,
    );
    await _runStage(
      WiredFlashStage.writingFirmware,
      '正在写入 firmware，完成后设备将重启…',
      [
        'write-bin',
        '--chip',
        'esp32',
        ...common,
        '--before',
        'no-reset',
        '--after',
        'hard-reset',
        _hex(firmware.offset),
        bundle.file('firmware.bin').path,
      ],
      onEvent,
      workingDirectory: bundle.directory.path,
    );
    onEvent?.call(
      const WiredFlashEvent(
        stage: WiredFlashStage.writingFirmware,
        message: '刷写完成，设备已硬复位。',
        completed: true,
      ),
    );
  }

  Future<WiredProcessResult> _runStage(
    WiredFlashStage stage,
    String message,
    List<String> arguments,
    void Function(WiredFlashEvent event)? onEvent, {
    required String workingDirectory,
  }) async {
    onEvent?.call(WiredFlashEvent(stage: stage, message: message));
    final result = await _run(
      arguments,
      workingDirectory: workingDirectory,
      onOutput: (line) => onEvent?.call(
        WiredFlashEvent(stage: stage, message: line, output: line),
      ),
    );
    if (result.exitCode != 0) {
      throw WiredRecoveryException(
        '${stage.label}失败（espflash 退出码 ${result.exitCode}）',
        stage: stage,
        output: result.output,
      );
    }
    return result;
  }

  Future<WiredProcessResult> _run(
    List<String> arguments, {
    required String workingDirectory,
    void Function(String line)? onOutput,
  }) async {
    final executable = _resolveExecutable();
    try {
      return await _executor.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        onOutput: onOutput,
      );
    } on WiredRecoveryException {
      rethrow;
    } catch (error) {
      throw WiredRecoveryException('无法启动 espflash：$error');
    }
  }

  String _resolveExecutable() {
    final configuredPath = _executablePath;
    if (configuredPath != null) return configuredPath;
    // Unit/integration fakes do not launch a real process, so they should not
    // need a platform-specific bundled executable just to inspect arguments.
    if (_executor is! IoWiredProcessExecutor) return 'espflash.exe';
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      p.join(executableDirectory, 'data', 'tools', 'espflash', 'espflash.exe'),
      p.join(executableDirectory, 'tools', 'espflash', 'espflash.exe'),
      p.join(
        Directory.current.path,
        'third_party',
        'espflash',
        'windows-x64',
        'espflash.exe',
      ),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    throw WiredRecoveryException('找不到内置 espflash.exe，请重新安装 Windows 版本程序');
  }

  static String _hex(int value) => '0x${value.toRadixString(16)}';

  static Map<String, WiredPartitionEntry> _parsePartitions(String text) {
    final entries = <String, WiredPartitionEntry>{};
    final lines = text.split(RegExp(r'\r?\n'));
    for (var index = 0; index < lines.length; index++) {
      var line = lines[index].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final comment = line.indexOf('#');
      if (comment >= 0) line = line.substring(0, comment).trim();
      if (line.isEmpty) continue;
      final fields = line.split(',').map((field) => field.trim()).toList();
      if (fields.length < 5 || fields[0].isEmpty) {
        throw WiredRecoveryException('partitions.csv 第 ${index + 1} 行格式错误');
      }
      final name = fields[0];
      if (entries.containsKey(name)) {
        throw WiredRecoveryException('partitions.csv 存在重复分区：$name');
      }
      if (fields[3].isEmpty || fields[4].isEmpty) {
        throw WiredRecoveryException('$name 分区必须显式定义偏移和大小');
      }
      final offset = _parseNumber(fields[3], '$name 偏移');
      final size = _parseNumber(fields[4], '$name 大小');
      if (offset < 0 || size <= 0 || offset + size > _flashSize) {
        throw WiredRecoveryException('$name 分区超出 4 MiB Flash 范围');
      }
      if (offset < _bootloaderLimit) {
        throw WiredRecoveryException('$name 分区覆盖固定 bootloader 区域');
      }
      if (offset < _partitionTableOffset + _partitionTableSize) {
        throw WiredRecoveryException('$name 分区覆盖固定分区表区域');
      }
      entries[name] = WiredPartitionEntry(
        name: name,
        type: fields[1],
        subtype: fields[2],
        offset: offset,
        size: size,
      );
    }

    for (final required in const ['bootctl', 'updater', 'firmware']) {
      if (!entries.containsKey(required)) {
        throw WiredRecoveryException('partitions.csv 缺少 $required 分区');
      }
    }
    final sorted = entries.values.toList()
      ..sort((a, b) => a.offset.compareTo(b.offset));
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i - 1].offset + sorted[i - 1].size > sorted[i].offset) {
        throw WiredRecoveryException(
          '分区 ${sorted[i - 1].name} 与 ${sorted[i].name} 存在重叠',
        );
      }
    }
    final bootctl = entries['bootctl']!;
    if (bootctl.offset % 0x1000 != 0 || bootctl.size % 0x1000 != 0) {
      throw WiredRecoveryException('bootctl 偏移和大小必须按 0x1000 对齐');
    }
    return entries;
  }

  static int _parseNumber(String raw, String label) {
    var value = raw.trim().toLowerCase();
    var multiplier = 1;
    if (value.endsWith('k')) {
      multiplier = 1024;
      value = value.substring(0, value.length - 1);
    } else if (value.endsWith('m')) {
      multiplier = 1024 * 1024;
      value = value.substring(0, value.length - 1);
    }
    try {
      final parsed = value.startsWith('0x')
          ? int.parse(value.substring(2), radix: 16)
          : int.parse(value);
      return parsed * multiplier;
    } catch (_) {
      throw WiredRecoveryException('$label 不是有效数值：$raw');
    }
  }

  static Map<String, _BinaryPartition> _parseBinaryPartitions(Uint8List bytes) {
    if (bytes.length > _partitionTableSize || bytes.length < 32) {
      throw WiredRecoveryException('partitions.bin 大小无效');
    }
    final entries = <String, _BinaryPartition>{};
    var sawEnd = false;
    for (var at = 0; at + 32 <= bytes.length; at += 32) {
      final magic = bytes[at] | (bytes[at + 1] << 8);
      if (magic == 0xffff || magic == 0xebeb) {
        sawEnd = true;
        break;
      }
      if (magic != 0x50aa) {
        throw WiredRecoveryException('partitions.bin 包含无效分区表记录');
      }
      final labelBytes = bytes.sublist(at + 12, at + 28);
      final end = labelBytes.indexOf(0);
      final label = utf8.decode(
        end < 0 ? labelBytes : labelBytes.sublist(0, end),
        allowMalformed: false,
      );
      if (label.isEmpty || entries.containsKey(label)) {
        throw WiredRecoveryException('partitions.bin 包含无效或重复分区名称');
      }
      entries[label] = _BinaryPartition(
        offset: _readU32(bytes, at + 4),
        size: _readU32(bytes, at + 8),
      );
    }
    if (!sawEnd || entries.isEmpty) {
      throw WiredRecoveryException('partitions.bin 缺少结束标记或分区记录');
    }
    return entries;
  }

  static int _readU32(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static void _verifyPartitionTables(
    Map<String, WiredPartitionEntry> csv,
    Map<String, _BinaryPartition> binary,
  ) {
    if (csv.length != binary.length || !csv.keys.every(binary.containsKey)) {
      throw WiredRecoveryException('partitions.csv 与 partitions.bin 的分区名称不一致');
    }
    for (final entry in csv.entries) {
      final binaryEntry = binary[entry.key]!;
      if (entry.value.offset != binaryEntry.offset ||
          entry.value.size != binaryEntry.size) {
        throw WiredRecoveryException('${entry.key} 的 CSV 与 BIN 偏移/大小不一致');
      }
    }
  }
}

class _BinaryPartition {
  const _BinaryPartition({required this.offset, required this.size});

  final int offset;
  final int size;
}
