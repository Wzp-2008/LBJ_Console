import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:lbjconsole/models/train_record.dart';
import 'package:lbjconsole/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Re-exported so test files need only `import 'helpers.dart';`. The FFI
// factory and Database/inMemoryDatabasePath types come from sqflite_common_ffi.
export 'package:sqflite_common_ffi/sqflite_ffi.dart' show databaseFactoryFfi, inMemoryDatabasePath, sqfliteFfiInit;
export 'package:lbjconsole/models/train_record.dart';
export 'package:lbjconsole/models/merged_record.dart';
export 'package:lbjconsole/services/database_service.dart';
export 'package:lbjconsole/services/records_feed.dart';
export 'package:lbjconsole/services/display_group_cache.dart';

/// Initializes the FFI database factory once for the test process and swaps
/// the [DatabaseService] singleton for one backed by a fresh in-memory
/// database (full schema + seeded settings).
///
/// Call from `setUp`; pair with [disposeTestDatabase] in `tearDown`.
Future<Database> initTestDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = await openDatabase(inMemoryDatabasePath);
  await DatabaseService.overrideForTesting(db);
  return db;
}

/// Tears down a DB set up by [initTestDb].
Future<void> disposeTestDatabase() async {
  await DatabaseService.instance.close();
  DatabaseService.resetForTesting();
}

/// Locates the sample data file `LBJ_Console_output.json` (32 696 records).
/// `flutter test` runs with the working directory at the project root, where
/// the file lives; the upward walk is a fallback.
String sampleJsonPath() {
  final direct = p.join(Directory.current.path, 'LBJ_Console_output.json');
  if (File(direct).existsSync()) return direct;
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = p.join(dir.path, 'LBJ_Console_output.json');
    if (File(candidate).existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return direct;
}

/// Builds a [TrainRecord] for tests with sensible defaults; only the fields
/// relevant to a given assertion need to be overridden.
TrainRecord mkRecord({
  required String uniqueId,
  required int receivedMs,
  String train = '',
  int direction = 0,
  String speed = '',
  String position = '',
  String time = '',
  String loco = '',
  String locoType = '',
  String lbjClass = '',
  String route = '',
  String positionInfo = '',
  double rssi = 0.0,
  int? timestampMs,
}) {
  return TrainRecord(
    uniqueId: uniqueId,
    timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs ?? receivedMs),
    receivedTimestamp: DateTime.fromMillisecondsSinceEpoch(receivedMs),
    train: train,
    direction: direction,
    speed: speed,
    position: position,
    time: time,
    loco: loco,
    locoType: locoType,
    lbjClass: lbjClass,
    route: route,
    positionInfo: positionInfo,
    rssi: rssi,
  );
}
