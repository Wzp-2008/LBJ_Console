import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'ble_service.dart';
import 'ble_diagnostics.dart';
import 'file_share_api.dart';
import 'recovery_ota.dart';

class FirmwareUpdateInfo {
  const FirmwareUpdateInfo({
    required this.version,
    required this.fileId,
    required this.fileName,
    required this.uploadTime,
  });

  final String version;
  final int fileId;
  final String fileName;
  final String? uploadTime;
}

class FirmwareOtaService {
  FirmwareOtaService({FileShareApi? api, BLEService? bleService})
    : _api = api ?? FileShareApi(),
      _bleService = bleService ?? BLEService();

  static const int _folderId = 3470;
  final FileShareApi _api;
  final BLEService _bleService;

  Future<FirmwareUpdateInfo?> checkForUpdate() async {
    final current = _bleService.firmwareVersion;
    if (!_bleService.isConnected) throw StateError('请先连接蓝牙设备');
    return _findFirmware(current: current);
  }

  /// Returns the newest firmware entry without requiring a BLE Main
  /// connection. This is used when the receiver is already in Updater SPP
  /// mode and therefore cannot report its current firmware version.
  Future<FirmwareUpdateInfo?> findLatestFirmware() {
    return _findFirmware();
  }

  Future<FirmwareUpdateInfo?> _findFirmware({String? current}) async {
    BleDiagnostics.log('Check firmware folder=$_folderId current=$current');
    final page = await _api.listFiles(
      folder: _folderId,
      page: 1,
      num: 100,
      sort: 'TIME',
      reverse: false,
    );
    final versionPattern = RegExp(r'^firmware-([0-9a-fA-F]{16})$');
    for (final item in page.files) {
      final extension = (item['ext'] ?? item['extension'] ?? '')
          .toString()
          .toLowerCase()
          .replaceFirst('.', '');
      if (extension != 'bin') continue;

      final baseName =
          (item['name'] ?? item['filename'] ?? item['fileName'] ?? '')
              .toString();
      final match = versionPattern.firstMatch(baseName);
      final fileId = _fileId(item);
      if (match == null || fileId == null) continue;

      final version = match.group(1)!.toUpperCase();
      if (version.toUpperCase() == current?.toUpperCase()) return null;
      return FirmwareUpdateInfo(
        version: version,
        fileId: fileId,
        fileName: '$baseName.$extension',
        uploadTime: _uploadTime(item),
      );
    }
    return null;
  }

  Future<void> installUpdate(
    FirmwareUpdateInfo update, {
    void Function(double progress)? onProgress,
    void Function(Map<String, dynamic> state)? onState,
  }) async {
    onState?.call({'state': 'downloading'});
    BleDiagnostics.log(
      'Download firmware id=${update.fileId} name=${update.fileName}',
    );
    final url = await _api.getDownloadUrl(fileId: update.fileId);
    final directory = Directory(
      p.join(Directory.systemTemp.path, 'LBJConsole', 'firmware_update'),
    );
    await directory.create(recursive: true);
    final firmware = File(p.join(directory.path, update.fileName));
    await _download(url, firmware, onProgress);

    final digest = (await sha256.bind(firmware.openRead()).first).toString();
    await _bleService.startFirmwareOta(
      firmware,
      sha256: digest,
      onState: onState,
      onProgress: onProgress,
    );
  }

  Future<void> installSppUpdate(
    FirmwareUpdateInfo update, {
    required SppConnector connectSpp,
    void Function(double progress)? onProgress,
    void Function(Map<String, dynamic> state)? onState,
  }) async {
    onState?.call({'state': 'downloading'});
    BleDiagnostics.log(
      'Download rescue firmware id=${update.fileId} name=${update.fileName}',
    );
    final url = await _api.getDownloadUrl(fileId: update.fileId);
    final directory = Directory(
      p.join(Directory.systemTemp.path, 'LBJConsole', 'firmware_update'),
    );
    await directory.create(recursive: true);
    final firmware = File(p.join(directory.path, update.fileName));
    await _download(url, firmware, onProgress);

    final digest = (await sha256.bind(firmware.openRead()).first).toString();
    final total = await firmware.length();

    Future<void> transferFromStart() => SppRecoveryOta(
      connectSpp: connectSpp,
      onState: onState,
      onProgress: onProgress,
      log: BleDiagnostics.log,
    ).run(firmware.openRead(), total, digest);

    try {
      await transferFromStart();
    } on SppAckTimeoutException {
      // The failed session has already been closed by SppRecoveryOta. A
      // retry must create a new SPP session and send OTA_START again; the
      // timed-out block is never retransmitted in the old session.
      BleDiagnostics.log('SPP ACK timeout; restarting rescue OTA from START');
      await transferFromStart();
    }
  }

  Future<void> _download(
    Uri url,
    File destination,
    void Function(double progress)? onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(url);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FileShareApiException(
          '固件下载失败（HTTP ${response.statusCode}）',
          statusCode: response.statusCode,
        );
      }
      final total = response.contentLength;
      var received = 0;
      final sink = destination.openWrite();
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
        await sink.close();
      } catch (_) {
        await sink.close();
        rethrow;
      }
      onProgress?.call(1);
    } finally {
      client.close(force: true);
    }
  }

  int? _fileId(Map<String, dynamic> item) {
    final value = item['id'] ?? item['fileId'];
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  String? _uploadTime(Map<String, dynamic> item) =>
      (item['time'] ?? item['uploadTime'] ?? item['createdAt'])?.toString();
}
