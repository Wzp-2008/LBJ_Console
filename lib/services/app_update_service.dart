import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'file_share_api.dart';
import 'http_download.dart';

const String appBuildHash = String.fromEnvironment(
  'LBJ_BUILD_HASH',
  defaultValue: 'debug',
);

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.hash,
    required this.fileName,
    required this.fileId,
    required this.uploadTime,
  });

  final String hash;
  final String fileName;
  final int fileId;
  final String? uploadTime;
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
      reverse: false,
    );
    final extension = Platform.isAndroid ? 'apk' : 'zip';
    final pattern = RegExp(r'^LBJ-Console-([0-9a-f]{8})$');

    for (final item in page.files) {
      final baseName = fileShareFileName(item);
      final itemExtension = fileShareExtension(item);
      if (itemExtension != extension) continue;
      final match = pattern.firstMatch(baseName);
      final fileId = fileShareId(item);
      if (match != null && fileId != null) {
        final hash = match.group(1)!;
        final name = '$baseName.$itemExtension';
        if (hash != appBuildHash) {
          return AppUpdateInfo(
            hash: hash,
            fileName: name,
            fileId: fileId,
            uploadTime: fileShareUploadTime(item),
          );
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
    final downloadedName = Platform.isWindows ? 'update.zip' : update.fileName;
    final downloaded = File(p.join(directory.path, downloadedName));
    await HttpDownload.download(url, downloaded, onProgress: onProgress);

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
    final zipPath = p.join(updateDirectory.path, 'update.zip');
    if (!await File(zipPath).exists()) {
      throw const FileShareApiException('更新目录中缺少 update.zip');
    }
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
    await File(
      p.join(directory.path, '.lbj-update-marker'),
    ).writeAsString('LBJ Console update\n');
    return directory;
  }

  static Future<void> cleanupFromArguments(List<String> args) async {
    if (!Platform.isWindows) return;
    const prefix = '--lbj-cleanup-dir=';
    for (final arg in args) {
      if (arg.startsWith(prefix)) {
        try {
          final path = arg.substring(prefix.length);
          if (await _isSafeUpdateDirectory(path)) {
            await Directory(path).delete(recursive: true);
          }
        } catch (_) {
          // Cleanup is best effort; a failed cleanup must not block startup.
        }
      }
    }
  }

  static Future<bool> _isSafeUpdateDirectory(String path) async {
    final directory = Directory(path);
    if (path.contains('..') || !await directory.exists()) return false;
    final root = Directory(p.join(Directory.systemTemp.path, 'LBJConsole'));
    final rootPath = p.normalize(root.absolute.path).toLowerCase();
    final targetPath = p.normalize(directory.absolute.path).toLowerCase();
    if (!p.isWithin(rootPath, targetPath)) return false;
    final name = p.basename(targetPath);
    if (!name.startsWith('update_')) return false;
    return await File(p.join(directory.path, '.lbj-update-marker')).exists();
  }
}
