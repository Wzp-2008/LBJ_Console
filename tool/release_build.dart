import 'dart:io';
import 'dart:math';

Future<void> main(List<String> args) async {
  if (args.length != 1 || !{'android', 'windows'}.contains(args[0])) {
    stderr.writeln('Usage: dart run tool/release_build.dart <android|windows>');
    exitCode = 2;
    return;
  }

  final hash = List.generate(
    8,
    (_) => Random.secure().nextInt(16).toRadixString(16),
  ).join();
  final define = '--dart-define=LBJ_BUILD_HASH=$hash';

  if (args[0] == 'android') {
    await _run('flutter', [
      'build',
      'apk',
      '--release',
      '--target-platform',
      'android-arm64',
      define,
    ]);
    final source = File('build/app/outputs/flutter-apk/app-release.apk');
    final target = File('LBJ-Console-$hash.apk');
    await source.copy(target.path);
    stdout.writeln('Built ${target.path}');
    return;
  }

  await _run('flutter', ['build', 'windows', '--release', define]);
  final target = 'LBJ-Console-$hash.zip';
  if (Platform.isWindows) {
    await _run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Compress-Archive -Path build/windows/x64/runner/Release/* '
          '-DestinationPath "$target" -Force',
    ]);
  } else {
    final releaseDirectory = Directory('build/windows/x64/runner/Release');
    final absoluteTarget = File(target).absolute.path;
    await _run('zip', [
      '-r',
      absoluteTarget,
      '.',
    ], workingDirectory: releaseDirectory.path);
  }
  stdout.writeln('Built $target');
}

Future<void> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    runInShell: true,
    workingDirectory: workingDirectory,
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) exit(result.exitCode);
}
