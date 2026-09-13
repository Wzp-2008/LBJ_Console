import 'dart:convert';
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

/// Locates the optional large sample data file `LBJ_Console_output.json`.
///
/// The real sample is intentionally ignored by git because it is large and
/// may contain private captures. CI therefore uses a deterministic generated
/// fixture with the same top-level JSON shape when the local sample is absent.
/// The fallback is large enough to exercise pagination and contains both
/// groupable and ungroupable records for the data-layer tests.
String sampleJsonPath() {
  final forceFallback = Platform.environment['LBJ_TEST_SYNTHETIC_SAMPLE'] == '1';
  final direct = p.join(Directory.current.path, 'LBJ_Console_output.json');
  if (!forceFallback && File(direct).existsSync()) return direct;
  var dir = Directory.current;
  if (!forceFallback) {
    for (var i = 0; i < 6; i++) {
      final candidate = p.join(dir.path, 'LBJ_Console_output.json');
      if (File(candidate).existsSync()) return candidate;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }

  final fallback = p.join(
    Directory.systemTemp.path,
    'lbj_console_test_sample_$pid.json',
  );
  final fallbackFile = File(fallback);
  if (!fallbackFile.existsSync()) {
    final baseMs = DateTime.utc(2024, 1, 1).millisecondsSinceEpoch;
    final records = <Map<String, dynamic>>[];

    // Keep more than one page of displayable records so pagination tests
    // exercise their cursor termination path.
    for (var i = 0; i < 400; i++) {
      final receivedMs = baseMs - i * 60000;
      records.add({
        'uniqueId': 'ci_$i',
        'timestamp': receivedMs,
        'receivedTimestamp': receivedMs,
        'train': 'T${i % 100}',
        'direction': i.isEven ? 1 : 3,
        'speed': '${40 + i % 80}',
        'position': '${100 + i % 300}',
        'time': '12:00',
        'loco': '4101${i.toString().padLeft(4, '0')}',
        'locoType': '测试车型',
        'lbjClass': 'K',
        'route': '测试线路',
        'positionInfo': '30.0 120.0',
        'rssi': -70.0,
      });
    }

    // These records deliberately have no train or loco key and must be
    // removed when hideUngroupableRecords is enabled.
    for (var i = 0; i < 20; i++) {
      final receivedMs = baseMs - (500 + i) * 60000;
      records.add({
        'uniqueId': 'ci_ungroupable_$i',
        'timestamp': receivedMs,
        'receivedTimestamp': receivedMs,
        'train': '',
        'direction': 1,
        'speed': '',
        'position': '',
        'time': '12:00',
        'loco': '',
        'locoType': '',
        'lbjClass': '',
        'route': '测试线路',
        'positionInfo': '',
        'rssi': -80.0,
      });
    }

    fallbackFile.writeAsStringSync(jsonEncode({'records': records}));
  }
  return fallback;
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
