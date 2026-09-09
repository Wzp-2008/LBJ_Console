import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'file_share_api.dart';

const String appBuildHash = String.fromEnvironment(
  'LBJ_BUILD_HASH',
  defaultValue: 'debug',
);

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.hash,
    required this.fileName,
    required this.fileId,
  });

  final String hash;
  final String fileName;
  final int fileId;
}

class AppUpdateService {
  AppUpdateService({FileShareApi? api}) : _api = api ?? FileShareApi();

  static const int _folderId = 3469;
  static const MethodChannel _androidChannel = MethodChannel(
    'lbjconsole/updater',
  );

  final FileShareApi _api;

  bool get isSupported => Platform.isAndroid || Platform.isWindows;

  Future<AppUpdateInfo?> checkForUpdate() async {
    if (!isSupported || appBuildHash == 'debug') return null;

    final page = await _api.listFiles(
      folder: _folderId,
      page: 1,
      num: 100,
      sort: 'TIME',
      reverse: true,
    );
    final extension = Platform.isAndroid ? 'apk' : 'zip';
    final pattern = RegExp(r'^LBJ-Console-([0-9a-f]{8})$');

    for (final item in page.files) {
      final baseName = _fileName(item);
      final itemExtension = _extension(item);
      if (itemExtension != extension) continue;
      final match = pattern.firstMatch(baseName);
      final fileId = _fileId(item);
      if (match != null && fileId != null) {
        final hash = match.group(1)!;
        final name = '$baseName.$itemExtension';
        if (hash != appBuildHash) {
          return AppUpdateInfo(hash: hash, fileName: name, fileId: fileId);
        }
        return null;
      }
    }
    return null;
  }

  Future<void> installUpdate(
    AppUpdateInfo update, {
    void Function(double progress)? onProgress,
  }) async {
    final url = await _api.getDownloadUrl(fileId: update.fileId);
    final directory = await _createUpdateDirectory(update.hash);
    final downloaded = File(p.join(directory.path, update.fileName));
    await _downloadWithProgress(url, downloaded, onProgress);

    if (Platform.isAndroid) {
      await _androidChannel.invokeMethod<void>('installApk', {
        'path': downloaded.path,
      });
      return;
    }

    final executable = File(Platform.resolvedExecutable);
    final installDirectory = executable.parent;
    final updater = await _findWindowsUpdater(installDirectory, directory);

    await Process.start(updater.path, [
      installDirectory.path,
      downloaded.path,
      directory.path,
    ], mode: ProcessStartMode.detached);
    _api.close();
    exit(0);
  }

  Future<File> _findWindowsUpdater(
    Directory installDirectory,
    Directory updateDirectory,
  ) async {
    final installedUpdater = File(
      p.join(installDirectory.path, 'lbj_updater.exe'),
    );
    if (await installedUpdater.exists()) return installedUpdater;

    // The first release containing the updater must also be able to update
    // installations created by older releases which do not have it yet.
    final bootstrapDirectory = Directory(
      p.join(updateDirectory.path, 'bootstrap'),
    );
    await bootstrapDirectory.create(recursive: true);
    final zipPath = Directory(updateDirectory.path)
        .listSync()
        .whereType<File>()
        .firstWhere((file) => file.path.toLowerCase().endsWith('.zip'))
        .path;
    final command =
        "Expand-Archive -LiteralPath '${_powerShellQuote(zipPath)}' "
        "-DestinationPath '${_powerShellQuote(bootstrapDirectory.path)}' -Force";
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      command,
    ]);
    if (result.exitCode != 0) {
      throw FileShareApiException('无法准备 Windows 更新器：${result.stderr}');
    }
    final extractedUpdater = File(
      p.join(bootstrapDirectory.path, 'lbj_updater.exe'),
    );
    if (!await extractedUpdater.exists()) {
      throw const FileShareApiException('更新包中缺少 Windows 更新器');
    }
    return extractedUpdater;
  }

  String _powerShellQuote(String value) => value.replaceAll("'", "''");

  Future<Directory> _createUpdateDirectory(String hash) async {
    final root = Directory(p.join(Directory.systemTemp.path, 'LBJConsole'));
    await root.create(recursive: true);
    final directory = Directory(
      p.join(
        root.path,
        'update_${hash}_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _downloadWithProgress(
    Uri url,
    File destination,
    void Function(double progress)? onProgress,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FileShareApiException(
          '下载更新失败（HTTP ${response.statusCode}）',
          statusCode: response.statusCode,
        );
      }
      final total = response.contentLength;
      var received = 0;
      final sink = destination.openWrite();
      try {
        await for (final chunk in response) {
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

  String _fileName(Map<String, dynamic> item) =>
      (item['name'] ?? item['filename'] ?? item['fileName'] ?? '').toString();

  String _extension(Map<String, dynamic> item) =>
      (item['ext'] ?? item['extension'] ?? '')
          .toString()
          .toLowerCase()
          .replaceFirst('.', '');

  int? _fileId(Map<String, dynamic> item) {
    final value = item['id'] ?? item['fileId'];
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static Future<void> cleanupFromArguments(List<String> args) async {
    if (!Platform.isWindows) return;
    const prefix = '--lbj-cleanup-dir=';
    for (final arg in args) {
      if (arg.startsWith(prefix)) {
        try {
          await Directory(arg.substring(prefix.length)).delete(recursive: true);
        } catch (_) {
          // Cleanup is best effort; a failed cleanup must not block startup.
        }
      }
    }
  }
}
