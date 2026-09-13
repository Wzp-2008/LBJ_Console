import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:lbjconsole/models/firmware_board.dart';

import 'ble_service.dart';
import 'ble_diagnostics.dart';
import 'file_share_api.dart';
import 'http_download.dart';
import 'recovery_ota.dart';

class FirmwareUpdateInfo {
  const FirmwareUpdateInfo({
    required this.version,
    required this.fileId,
    required this.fileName,
    required this.uploadTime,
    required this.board,
  });

  final String version;
  final int fileId;
  final String fileName;
  final String? uploadTime;
  final FirmwareBoard board;
}

class FirmwareOtaService {
  FirmwareOtaService({FileShareApi? api, BLEService? bleService})
    : _api = api ?? FileShareApi(),
      _bleService = bleService ?? BLEService();

  final FileShareApi _api;
  final BLEService _bleService;

  Future<FirmwareUpdateInfo?> checkForUpdate(FirmwareBoard board) async {
    final current = _bleService.firmwareVersion;
    if (!_bleService.isConnected) throw StateError('请先连接蓝牙设备');
    return _findFirmware(board, current: current);
  }

  /// Returns the newest firmware entry without requiring a BLE Main
  /// connection. This is used when the receiver is already in Updater SPP
  /// mode and therefore cannot report its current firmware version.
  Future<FirmwareUpdateInfo?> findLatestFirmware(FirmwareBoard board) {
    return _findFirmware(board);
  }

  Future<FirmwareUpdateInfo?> _findFirmware(
    FirmwareBoard board, {
    String? current,
  }) async {
    BleDiagnostics.log(
      'Check firmware board=${board.wireName} folder=${board.folderId} current=$current',
    );
    final page = await _api.listFiles(
      folder: board.folderId,
      page: 1,
      num: 100,
      sort: 'TIME',
      reverse: false,
    );
    final versionPattern = RegExp(r'^firmware-([0-9a-fA-F]{16})$');
    for (final item in page.files) {
      final extension = fileShareExtension(item);
      if (extension != 'bin') continue;

      final baseName = fileShareFileName(item);
      final match = versionPattern.firstMatch(baseName);
      final fileId = fileShareId(item);
      if (match == null || fileId == null) continue;

      final version = match.group(1)!.toUpperCase();
      if (version.toUpperCase() == current?.toUpperCase()) return null;
      return FirmwareUpdateInfo(
        version: version,
        fileId: fileId,
        fileName: '$baseName.$extension',
        uploadTime: fileShareUploadTime(item),
        board: board,
      );
    }
    return null;
  }

  Future<void> installUpdate(
    FirmwareUpdateInfo update, {
    void Function(double progress)? onProgress,
    void Function(Map<String, dynamic> state)? onState,
  }) async {
    final downloaded = await _fetchFirmware(
      update,
      logMessage: 'Download firmware',
      onProgress: onProgress,
      onState: onState,
    );
    final firmware = downloaded.$1;
    final digest = downloaded.$2;
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
    final downloaded = await _fetchFirmware(
      update,
      logMessage: 'Download rescue firmware',
      onProgress: onProgress,
      onState: onState,
    );
    final firmware = downloaded.$1;
    final digest = downloaded.$2;
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

  Future<(File, String)> _fetchFirmware(
    FirmwareUpdateInfo update, {
    required String logMessage,
    void Function(double progress)? onProgress,
    void Function(Map<String, dynamic> state)? onState,
  }) async {
    onState?.call({'state': 'downloading'});
    BleDiagnostics.log(
      '$logMessage id=${update.fileId} name=${update.fileName}',
    );
    final url = await _api.getDownloadUrl(fileId: update.fileId);
    final directory = Directory(
      p.join(Directory.systemTemp.path, 'LBJConsole', 'firmware_update'),
    );
    await directory.create(recursive: true);
    final firmware = File(p.join(directory.path, update.fileName));
    await HttpDownload.download(url, firmware, onProgress: onProgress);
    final digest = (await sha256.bind(firmware.openRead()).first).toString();
    return (firmware, digest);
  }
}
