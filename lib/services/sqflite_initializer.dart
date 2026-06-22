import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _initialized = false;

/// Uses [sqlite3_flutter_libs] on mobile and FFI on desktop so SQLite includes FTS5.
/// Must run before any [openDatabase] call (e.g. in [main]).
Future<void> initializeSqflite() async {
  if (_initialized || kIsWeb) return;

  final useBundledSqlite = Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS;

  if (!useBundledSqlite) return;

  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  _initialized = true;
}
