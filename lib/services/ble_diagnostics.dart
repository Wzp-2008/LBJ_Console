import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Keep release diagnostics too, even when the GUI has no attached console.
class BleDiagnostics {
  static String get logPath =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}LBJ-Console-BLE.log';
  static Future<void> _pending = Future.value();

  static void log(String message, [Object? error, StackTrace? stack]) {
    final line =
        '${DateTime.now().toIso8601String()} [BLE] $message'
        '${error == null ? '' : ' | $error'}${stack == null ? '' : '\n$stack'}';
    debugPrint(line);
    developer.log(message, name: 'LBJ.BLE', error: error, stackTrace: stack);
    _pending = _pending
        .then((_) async {
          final file = File(logPath);
          if (await file.exists() && await file.length() > 4 * 1024 * 1024) {
            await file.writeAsString('');
          }
          await file.writeAsString(
            '$line\n',
            mode: FileMode.append,
            flush: true,
          );
        })
        .catchError((Object e) {
          debugPrint('[BLE] Cannot write log: $e');
        });
  }
}
