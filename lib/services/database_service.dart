import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'dart:io';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:lbjconsole/models/train_record.dart';
import 'package:lbjconsole/services/display_group_cache.dart';
import 'package:lbjconsole/services/sqflite_initializer.dart';

enum InputSource {
  bluetooth,
  rtlTcp,
  audioInput
}

class DatabaseService {
  // Singleton. `instance` is a getter so tests can swap in a DatabaseService
  // backed by an in-memory database via [overrideForTesting]; in production
  // it always returns the lazily-initialized [_default].
  static final DatabaseService _default = DatabaseService._internal();
  static DatabaseService? _testOverride;
  static DatabaseService get instance => _testOverride ?? _default;
  factory DatabaseService() => instance;
  DatabaseService._internal();

  static const String _databaseName = 'train_database';
  static const _databaseVersion = 17;

  static const String trainRecordsTable = 'train_records';
  static const String trainRecordsFtsTable = 'train_records_fts';
  static const String appSettingsTable = 'app_settings';
  static const int mapDisplayRecordLimit = 10000;
  static const int _maxFuzzyCharGapLength = 10;
  static const int _exportBatchSize = 500;

  Database? _database;
  bool _fts5Available = false;
  Map<String, dynamic>? _settingsCache;
  Future<void> _dbQueue = Future.value();

  Future<T> _runInDbQueue<T>(Future<T> Function() action) {
    final result = _dbQueue.then((_) => action());
    _dbQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Database> get database async {
    try {
      if (_database != null) {
        return _database!;
      }
      _database = await _initDatabase();
      return _database!;
    } catch (e) {
      rethrow;
    }
  }

  Future<bool> isDatabaseConnected() async {
    try {
      if (_database == null) {
        return false;
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Connection-wide SQLite tuning applied once when the database is opened.
  /// WAL + synchronous=NORMAL give fast bulk writes (import + live inserts)
  /// with acceptable durability for a local console app; temp_store=memory
  /// and a larger page cache speed up the large sort/join reads the list
  /// performs. On in-memory databases (tests) journal_mode=WAL is a no-op.
  Future<void> _onConfigure(Database db) async {
    await _applyPragmas(db);
  }

  Future<void> _applyPragmas(DatabaseExecutor db) async {
    await db.rawQuery('PRAGMA journal_mode=WAL');
    await db.execute('PRAGMA synchronous=NORMAL');
    await db.execute('PRAGMA temp_store=MEMORY');
    await db.execute('PRAGMA cache_size=-65536');
  }

  Future<Database> _initDatabase() async {
    try {
      await initializeSqflite();

      final directory = await getApplicationDocumentsDirectory();
      final path = join(directory.path, _databaseName);
      final db = await openDatabase(
        path,
        version: _databaseVersion,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
      _fts5Available = await _probeFts5Available(db);
      if (_fts5Available && !await _tableExists(db, trainRecordsFtsTable)) {
        await _createFtsTable(db);
        await _rebuildFtsTable(db);
      }

      // Safety net: rebuild the merge cache if it is missing while records
      // exist (e.g. interrupted migration).
      if (await DisplayGroupCache.isEmpty(db)) {
        final countRows =
            await db.rawQuery('SELECT COUNT(*) AS cnt FROM $trainRecordsTable');
        final count = (countRows.first['cnt'] as num?)?.toInt() ?? 0;
        if (count > 0) {
          await DisplayGroupCache.rebuild(db, recordsTable: trainRecordsTable);
        }
      }

      return db;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    developer.log('Database upgrading from $oldVersion to $newVersion', name: 'Database');

    if (oldVersion < 2) {
      await db.execute(
          'ALTER TABLE $appSettingsTable ADD COLUMN hideTimeOnlyRecords INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 3) {
      await db.execute(
          'ALTER TABLE $appSettingsTable ADD COLUMN mapTimeFilter TEXT NOT NULL DEFAULT "unlimited"');
    }
    if (oldVersion < 4) {
      try {
        await db.execute(
            'ALTER TABLE $appSettingsTable ADD COLUMN mapTimeFilter TEXT NOT NULL DEFAULT "unlimited"');
      } catch (e) {}
    }
    if (oldVersion < 5) {
      await db.execute(
          'ALTER TABLE $appSettingsTable ADD COLUMN mapType TEXT NOT NULL DEFAULT "webview"');
    }
    if (oldVersion < 6) {
      await db.execute(
          'ALTER TABLE $appSettingsTable ADD COLUMN hideUngroupableRecords INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 7) {
      await db.execute(
          'ALTER TABLE $appSettingsTable ADD COLUMN mapSettingsTimestamp INTEGER');
    }
    if (oldVersion < 8) {
      await db.execute(
          'ALTER TABLE $appSettingsTable ADD COLUMN rtlTcpEnabled INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE $appSettingsTable ADD COLUMN rtlTcpHost TEXT NOT NULL DEFAULT "127.0.0.1"');
      await db.execute(
          'ALTER TABLE $appSettingsTable ADD COLUMN rtlTcpPort TEXT NOT NULL DEFAULT "14423"');
    }
    if (oldVersion < 9) {
      await db.execute(
          'ALTER TABLE $appSettingsTable ADD COLUMN inputSource TEXT NOT NULL DEFAULT "bluetooth"');

      try {
        final List<Map<String, dynamic>> results = await db.query(appSettingsTable, columns: ['rtlTcpEnabled'], where: 'id = 1');
        if (results.isNotEmpty) {
          final int rtlTcpEnabled = results.first['rtlTcpEnabled'] as int? ?? 0;
          if (rtlTcpEnabled == 1) {
            await db.update(
              appSettingsTable,
              {'inputSource': 'rtlTcp'},
              where: 'id = 1'
            );
            developer.log('Migrated V8 settings: inputSource set to rtlTcp', name: 'Database');
          }
        }
      } catch (e) {
        developer.log('Migration V8->V9 data update failed: $e', name: 'Database');
      }
    }
    if (oldVersion < 10) {
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_records_timestamp ON $trainRecordsTable(timestamp)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_records_received ON $trainRecordsTable(receivedTimestamp)');
    }
    if (oldVersion < 11) {
      await _ensureSearchTextColumn(db);
    }
    if (oldVersion < 12) {
      await _ensureSearchTextColumn(db);
      _fts5Available = await _probeFts5Available(db);
      if (_fts5Available) {
        if (!await _tableExists(db, trainRecordsFtsTable)) {
          await _createFtsTable(db);
        }
        await _rebuildFtsTable(db);
      } else {
        developer.log(
          'FTS5 unavailable on this platform; search uses LIKE only',
          name: 'Database',
        );
      }
    }
    if (oldVersion < 13) {
      await DisplayGroupCache.ensureTables(db);
    }
    if (oldVersion < 14) {
      await _backfillSearchText(db);
      _fts5Available = await _probeFts5Available(db);
      if (_fts5Available) {
        await _rebuildFtsTable(db);
      }
    }
    if (oldVersion < 15) {
      await _ensureDerivedColumns(db);
      await DisplayGroupCache.dropLegacyTables(db);
      await DisplayGroupCache.ensureTables(db);
      await DisplayGroupCache.rebuild(db, recordsTable: trainRecordsTable);
    }
    if (oldVersion == 15) {
      // v15 caches were built with span-based eviction; rebuild with the
      // session-window grouping semantics.
      await DisplayGroupCache.rebuild(db, recordsTable: trainRecordsTable);
    }
    if (oldVersion < 17) {
      // Covering indexes for keyset pagination on the stable total orders
      // `(latestReceivedTimestamp DESC, groupId ASC)` (merged) and
      // `(receivedTimestamp DESC, uniqueId DESC)` (raw). Additive only — no
      // data migration, no cache rebuild; existing cache rows are queryable
      // as-is.
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_mdg_cursor ON ${DisplayGroupCache.groupsTable}(latestReceivedTimestamp DESC, groupId ASC)');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_records_cursor ON $trainRecordsTable(receivedTimestamp DESC, uniqueId DESC)');
    }
  }

  Future<void> _ensureDerivedColumns(Database db) async {
    if (!await _columnExists(db, trainRecordsTable, 'isTimeOnly')) {
      await db.execute(
          'ALTER TABLE $trainRecordsTable ADD COLUMN isTimeOnly INTEGER NOT NULL DEFAULT 0');
    }
    if (!await _columnExists(db, trainRecordsTable, 'trainKey')) {
      await db.execute(
          'ALTER TABLE $trainRecordsTable ADD COLUMN trainKey TEXT');
    }
    if (!await _columnExists(db, trainRecordsTable, 'locoKey')) {
      await db.execute(
          'ALTER TABLE $trainRecordsTable ADD COLUMN locoKey TEXT');
    }
    await _backfillDerivedColumns(db);
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_records_trainkey ON $trainRecordsTable(trainKey)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_records_locokey ON $trainRecordsTable(locoKey)');
  }

  Future<void> _backfillDerivedColumns(Database db) async {
    const chunkSize = 1000;
    var offset = 0;
    while (true) {
      final rows = await db.query(
        trainRecordsTable,
        limit: chunkSize,
        offset: offset,
        orderBy: 'uniqueId ASC',
      );
      if (rows.isEmpty) break;
      final batch = db.batch();
      for (final row in rows) {
        final record = TrainRecord.fromDatabaseJson(row);
        batch.update(
          trainRecordsTable,
          record.derivedColumns(),
          where: 'uniqueId = ?',
          whereArgs: [record.uniqueId],
        );
      }
      await batch.commit(noResult: true);
      if (rows.length < chunkSize) break;
      offset += rows.length;
    }
  }

  ({
    String whereSql,
    List<dynamic> whereArgs,
  }) _buildSearchWhere(String normalizedQuery) {
    final filters = _buildSearchFilters(normalizedQuery);
    return (
      whereSql: filters.whereClauses.map((c) => '($c)').join(' OR '),
      whereArgs: filters.whereArgs,
    );
  }

  ({
    String whereSql,
    List<dynamic> whereArgs,
  }) _buildSearchWhereFallback(String normalizedQuery) {
    final filters = _buildSearchFilters(normalizedQuery);
    final whereSql = filters.charGapPattern != null
        ? 'searchText LIKE ? OR searchText LIKE ?'
        : 'searchText LIKE ?';
    final whereArgs = filters.charGapPattern != null
        ? [filters.containsPattern, filters.charGapPattern!]
        : [filters.containsPattern];
    return (whereSql: whereSql, whereArgs: whereArgs);
  }

  Future<bool> _columnExists(Database db, String table, String column) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.any((row) => row['name'] == column);
  }

  Future<bool> _tableExists(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [table],
    );
    return rows.isNotEmpty;
  }

  Future<bool> _probeFts5Available(Database db) async {
    try {
      await db.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS _fts5_probe USING fts5(content)",
      );
      await db.execute('DROP TABLE IF EXISTS _fts5_probe');
      return true;
    } catch (e) {
      developer.log('FTS5 probe failed: $e', name: 'Database');
      return false;
    }
  }

  Future<void> _ensureSearchTextColumn(Database db) async {
    if (await _columnExists(db, trainRecordsTable, 'searchText')) {
      return;
    }
    await db.execute(
      'ALTER TABLE $trainRecordsTable ADD COLUMN searchText TEXT NOT NULL DEFAULT ""',
    );
    await _backfillSearchText(db);
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_search ON $trainRecordsTable(searchText)',
    );
  }

  Future<void> _createFtsTable(Database db) async {
    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS $trainRecordsFtsTable USING fts5(
        uniqueId UNINDEXED,
        searchText,
        tokenize='unicode61 remove_diacritics 2'
      )
    ''');
  }

  Future<void> _rebuildFtsTable(Database db) async {
    if (!_fts5Available || !await _tableExists(db, trainRecordsFtsTable)) {
      return;
    }
    await db.delete(trainRecordsFtsTable);
    final rows = await db.query(trainRecordsTable, columns: ['uniqueId', 'searchText']);
    if (rows.isEmpty) return;
    final batch = db.batch();
    for (final row in rows) {
      batch.insert(trainRecordsFtsTable, {
        'uniqueId': row['uniqueId'],
        'searchText': row['searchText'] ?? '',
      });
    }
    await batch.commit(noResult: true);
  }

  Future<void> _syncFtsUpsert(DatabaseExecutor db, String uniqueId, String searchText) async {
    if (!_fts5Available) return;
    await db.delete(trainRecordsFtsTable, where: 'uniqueId = ?', whereArgs: [uniqueId]);
    await db.insert(trainRecordsFtsTable, {
      'uniqueId': uniqueId,
      'searchText': searchText,
    });
  }

  Future<void> _syncFtsDelete(DatabaseExecutor db, String uniqueId) async {
    if (!_fts5Available) return;
    await db.delete(trainRecordsFtsTable, where: 'uniqueId = ?', whereArgs: [uniqueId]);
  }

  String _escapeFtsToken(String token) => token.replaceAll('"', '""');

  String _buildFtsPrefixQuery(String normalizedQuery) {
    final escaped = _escapeFtsToken(normalizedQuery);
    return '"$escaped"*';
  }

  String? _normalizeSearchQuery(String query) {
    final normalized = query.replaceAll('-', '').trim().toLowerCase();
    return normalized.isEmpty ? null : normalized;
  }

  bool _isTrainLikeQuery(String normalizedQuery) {
    return RegExp(r'^[a-z]{1,4}\d+$').hasMatch(normalizedQuery);
  }

  ({
    String containsPattern,
    String? charGapPattern,
    String ftsQuery,
    List<String> whereClauses,
    List<dynamic> whereArgs,
  }) _buildSearchFilters(String normalizedQuery) {
    final containsPattern = '%$normalizedQuery%';
    final charGapPattern =
        !_isTrainLikeQuery(normalizedQuery) &&
            normalizedQuery.length <= _maxFuzzyCharGapLength
        ? '%${normalizedQuery.split('').join('%')}%'
        : null;
    final ftsQuery = _buildFtsPrefixQuery(normalizedQuery);

    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    if (_fts5Available) {
      whereClauses.add(
        'r.uniqueId IN (SELECT uniqueId FROM $trainRecordsFtsTable WHERE searchText MATCH ?)',
      );
      whereArgs.add(ftsQuery);
    }

    whereClauses.add('r.searchText LIKE ?');
    whereArgs.add(containsPattern);

    whereClauses.add(
      "replace(lower(r.lbjClass || r.train), '-', '') LIKE ?",
    );
    whereArgs.add(containsPattern);

    whereClauses.add("replace(lower(r.route), '-', '') LIKE ?");
    whereArgs.add(containsPattern);

    whereClauses.add("replace(lower(r.positionInfo), '-', '') LIKE ?");
    whereArgs.add(containsPattern);

    if (!_isTrainLikeQuery(normalizedQuery)) {
      whereClauses.add(
        "replace(lower(r.locoType || r.loco), '-', '') LIKE ?",
      );
      whereArgs.add(containsPattern);
      whereClauses.add("replace(lower(r.loco), '-', '') LIKE ?");
      whereArgs.add(containsPattern);
    }

    if (charGapPattern != null && charGapPattern != containsPattern) {
      whereClauses.add('r.searchText LIKE ?');
      whereArgs.add(charGapPattern);
    }

    return (
      containsPattern: containsPattern,
      charGapPattern: charGapPattern,
      ftsQuery: ftsQuery,
      whereClauses: whereClauses,
      whereArgs: whereArgs,
    );
  }

  static const String _searchRelevanceScoreSql = '''
(CASE
  WHEN replace(lower(r.lbjClass || r.train), '-', '') = ? THEN 1000
  WHEN replace(lower(r.locoType || r.loco), '-', '') = ? THEN 990
  WHEN replace(lower(r.loco), '-', '') = ? THEN 985
  WHEN r.searchText = ? THEN 980
  WHEN r.searchText LIKE ? THEN 970
  WHEN r.searchText LIKE ?
       AND (length(r.searchText) = length(?) OR substr(r.searchText, length(?) + 1, 1) = ' ') THEN 960
  WHEN r.searchText LIKE ? OR r.searchText LIKE ? THEN 930
  WHEN replace(lower(r.lbjClass || r.train), '-', '') LIKE ? THEN 920
  WHEN replace(lower(r.locoType || r.loco), '-', '') LIKE ? THEN 910
  WHEN r.searchText LIKE ? THEN 700
  WHEN r.searchText LIKE ? THEN 650
  ELSE 550
END)''';

  List<dynamic> _searchRelevanceScoreArgs(String normalizedQuery) {
    final prefixPattern = '$normalizedQuery%';
    return [
      normalizedQuery,
      normalizedQuery,
      normalizedQuery,
      normalizedQuery,
      '$normalizedQuery %',
      prefixPattern,
      normalizedQuery,
      normalizedQuery,
      '% $normalizedQuery %',
      '% $normalizedQuery',
      prefixPattern,
      prefixPattern,
      prefixPattern,
      '%$normalizedQuery%',
    ];
  }

  String get _searchOrderByClause =>
      '$_searchRelevanceScoreSql DESC, r.receivedTimestamp DESC, r.uniqueId ASC';

  Future<void> _backfillSearchText(Database db) async {
    final rows = await db.query(trainRecordsTable);
    if (rows.isEmpty) return;
    final batch = db.batch();
    for (final row in rows) {
      final searchText = TrainRecord.buildSearchText(
        lbjClass: row['lbjClass']?.toString() ?? '',
        train: row['train']?.toString() ?? '',
        locoType: row['locoType']?.toString() ?? '',
        loco: row['loco']?.toString() ?? '',
        route: row['route']?.toString() ?? '',
        positionInfo: row['positionInfo']?.toString() ?? '',
      );
      batch.update(
        trainRecordsTable,
        {'searchText': searchText},
        where: 'uniqueId = ?',
        whereArgs: [row['uniqueId']],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $trainRecordsTable (
        uniqueId TEXT PRIMARY KEY,
        timestamp INTEGER NOT NULL,
        receivedTimestamp INTEGER NOT NULL,
        train TEXT NOT NULL,
        direction INTEGER NOT NULL,
        speed TEXT NOT NULL,
        position TEXT NOT NULL,
        time TEXT NOT NULL,
        loco TEXT NOT NULL,
        locoType TEXT NOT NULL,
        lbjClass TEXT NOT NULL,
        route TEXT NOT NULL,
        positionInfo TEXT NOT NULL,
        rssi REAL NOT NULL,
        searchText TEXT NOT NULL DEFAULT '',
        isTimeOnly INTEGER NOT NULL DEFAULT 0,
        trainKey TEXT,
        locoKey TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $appSettingsTable (
        id INTEGER PRIMARY KEY,
        deviceName TEXT NOT NULL DEFAULT 'LBJReceiver',
        currentTab INTEGER NOT NULL DEFAULT 0,
        historyEditMode INTEGER NOT NULL DEFAULT 0,
        historySelectedRecords TEXT NOT NULL DEFAULT '',
        historyExpandedStates TEXT NOT NULL DEFAULT '',
        historyScrollPosition INTEGER NOT NULL DEFAULT 0,
        historyScrollOffset INTEGER NOT NULL DEFAULT 0,
        settingsScrollPosition INTEGER NOT NULL DEFAULT 0,
        mapCenterLat REAL,
        mapCenterLon REAL,
        mapZoomLevel REAL NOT NULL DEFAULT 10.0,
        mapRailwayLayerVisible INTEGER NOT NULL DEFAULT 1,
        mapRotation REAL NOT NULL DEFAULT 0.0,
        mapType TEXT NOT NULL DEFAULT 'webview',
        specifiedDeviceAddress TEXT,
        searchOrderList TEXT NOT NULL DEFAULT '',
        autoConnectEnabled INTEGER NOT NULL DEFAULT 1,
        backgroundServiceEnabled INTEGER NOT NULL DEFAULT 0,
        notificationEnabled INTEGER NOT NULL DEFAULT 0,
        mergeRecordsEnabled INTEGER NOT NULL DEFAULT 0,
        hideTimeOnlyRecords INTEGER NOT NULL DEFAULT 0,
        groupBy TEXT NOT NULL DEFAULT 'trainAndLoco',
        timeWindow TEXT NOT NULL DEFAULT 'unlimited',
        mapTimeFilter TEXT NOT NULL DEFAULT 'unlimited',
        hideUngroupableRecords INTEGER NOT NULL DEFAULT 0,
        mapSettingsTimestamp INTEGER,
        rtlTcpEnabled INTEGER NOT NULL DEFAULT 0,
        rtlTcpHost TEXT NOT NULL DEFAULT '127.0.0.1',
        rtlTcpPort TEXT NOT NULL DEFAULT '14423',
        inputSource TEXT NOT NULL DEFAULT 'bluetooth'
      )
    ''');

    await db.insert(appSettingsTable, {
      'id': 1,
      'deviceName': 'LBJReceiver',
      'currentTab': 0,
      'historyEditMode': 0,
      'historySelectedRecords': '',
      'historyExpandedStates': '',
      'historyScrollPosition': 0,
      'historyScrollOffset': 0,
      'settingsScrollPosition': 0,
      'mapZoomLevel': 10.0,
      'mapRailwayLayerVisible': 1,
      'mapRotation': 0.0,
      'mapType': 'webview',
      'searchOrderList': '',
      'autoConnectEnabled': 1,
      'backgroundServiceEnabled': 0,
      'notificationEnabled': 0,
      'mergeRecordsEnabled': 0,
      'hideTimeOnlyRecords': 0,
      'groupBy': 'trainAndLoco',
      'timeWindow': 'unlimited',
      'mapTimeFilter': 'unlimited',
      'hideUngroupableRecords': 0,
      'mapSettingsTimestamp': null,
      'rtlTcpEnabled': 0,
      'rtlTcpHost': '127.0.0.1',
      'rtlTcpPort': '14423',
      'inputSource': 'bluetooth',
    });

    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_records_timestamp ON $trainRecordsTable(timestamp)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_records_received ON $trainRecordsTable(receivedTimestamp)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_records_search ON $trainRecordsTable(searchText)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_records_cursor ON $trainRecordsTable(receivedTimestamp DESC, uniqueId DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_records_trainkey ON $trainRecordsTable(trainKey)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_records_locokey ON $trainRecordsTable(locoKey)');
    _fts5Available = await _probeFts5Available(db);
    if (_fts5Available) {
      await _createFtsTable(db);
    }
    await DisplayGroupCache.ensureTables(db);
  }

  Future<int> insertRecord(TrainRecord record) async {
    return _runInDbQueue(() async {
      final db = await database;
      final json = record.toDatabaseJson()..addAll(record.derivedColumns());
      final result = await db.insert(
        trainRecordsTable,
        json,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _syncFtsUpsert(db, record.uniqueId, record.searchText);
      await DisplayGroupCache.applyNewRecord(
        db,
        recordsTable: trainRecordsTable,
        record: record,
      );
      return result;
    });
  }

  Future<List<TrainRecord>> getAllRecords({int? limit}) async {
    return _runInDbQueue(() async {
      final db = await database;
      final result = await db.query(
        trainRecordsTable,
        orderBy: 'receivedTimestamp DESC',
        limit: limit,
      );
      return result.map((json) => TrainRecord.fromDatabaseJson(json)).toList();
    });
  }

  Future<List<TrainRecord>> getRecentRecords({int limit = mapDisplayRecordLimit}) async {
    return getRecordsBatch(limit: limit, offset: 0);
  }

  Future<List<TrainRecord>> getRecordsWithinTimeRange(Duration duration,
      {int? limit}) async {
    return _runInDbQueue(() async {
      final db = await database;
      final cutoffTime = DateTime.now().subtract(duration).millisecondsSinceEpoch;
      final result = await db.query(
        trainRecordsTable,
        where: 'timestamp >= ?',
        whereArgs: [cutoffTime],
        orderBy: 'receivedTimestamp DESC',
        limit: limit,
      );
      return result.map((json) => TrainRecord.fromDatabaseJson(json)).toList();
    });
  }

  Future<List<TrainRecord>> getRecordsWithinReceivedTimeRange(
      Duration duration,
      {int? limit}) async {
    return _runInDbQueue(() async {
      final db = await database;
      final cutoffTime =
          DateTime.now().subtract(duration).millisecondsSinceEpoch;

      final result = await db.query(
        trainRecordsTable,
        where: 'receivedTimestamp >= ?',
        whereArgs: [cutoffTime],
        orderBy: 'receivedTimestamp DESC',
        limit: limit,
      );
      return result.map((json) => TrainRecord.fromDatabaseJson(json)).toList();
    });
  }

  Future<int> deleteRecord(String uniqueId) async {
    return _runInDbQueue(() async {
      final db = await database;
      final result = await db.delete(
        trainRecordsTable,
        where: 'uniqueId = ?',
        whereArgs: [uniqueId],
      );

      if (result > 0) {
        await _syncFtsDelete(db, uniqueId);
        await DisplayGroupCache.removeRecords(
          db,
          recordsTable: trainRecordsTable,
          uniqueIds: [uniqueId],
        );
        _notifyRecordDeleted([uniqueId]);
      }

      return result;
    });
  }

  Future<int> deleteAllRecords() async {
    return _runInDbQueue(() async {
      final db = await database;
      final result = await db.delete(trainRecordsTable);
      if (_fts5Available) {
        await db.delete(trainRecordsFtsTable);
      }
      await DisplayGroupCache.clear(db);

      if (result > 0) {
        _notifyRecordDeleted([]);
      }

      return result;
    });
  }

  Future<int> getRecordCount() async {
    return _runInDbQueue(() async {
      final db = await database;
      final result = await db.rawQuery('SELECT COUNT(*) FROM $trainRecordsTable');
      return Sqflite.firstIntValue(result) ?? 0;
    });
  }

  Future<List<TrainRecord>> getRecordsBatch({required int limit, required int offset}) async {
    return _runInDbQueue(() async {
      final db = await database;
      final result = await db.query(
        trainRecordsTable,
        orderBy: 'receivedTimestamp DESC',
        limit: limit,
        offset: offset,
      );
      return result.map((json) => TrainRecord.fromDatabaseJson(json)).toList();
    });
  }

  /// Paged merged display items, newest group first (keyset pagination).
  /// Pass [cursor] from the previous page's result to load the next page;
  /// null for the first page. Returns the items plus the cursor for the
  /// following page (null when this was the last page).
  Future<DisplayPageResult> fetchDisplayPage({
    required int limit,
    PageCursor? cursor,
    bool hideUngroupable = false,
  }) async {
    return _runInDbQueue(() async {
      final db = await database;
      return DisplayGroupCache.fetchPage(
        db,
        recordsTable: trainRecordsTable,
        limit: limit,
        cursor: cursor,
        hideUngroupable: hideUngroupable,
      );
    });
  }

  /// Paged raw records (merge disabled path), newest first (keyset
  /// pagination). Time-only records are excluded. When [hideUngroupable] is
  /// set, records with neither a train key nor a loco key are also excluded
  /// (the same "ungroupable" definition used by the merged path), so the
  /// option works regardless of merge mode.
  Future<DisplayPageResult> fetchPlainPage({
    required int limit,
    PageCursor? cursor,
    bool hideUngroupable = false,
  }) async {
    return _runInDbQueue(() async {
      final db = await database;
      final where = <String>['isTimeOnly = 0'];
      final args = <dynamic>[];
      if (hideUngroupable) {
        where.add('(trainKey IS NOT NULL OR locoKey IS NOT NULL)');
      }
      if (cursor != null) {
        where.add(
          '(receivedTimestamp < ? OR (receivedTimestamp = ? AND uniqueId < ?))',
        );
        args.addAll([cursor.timestamp, cursor.timestamp, cursor.id]);
      }
      final rows = await db.query(
        trainRecordsTable,
        where: where.join(' AND '),
        whereArgs: args,
        orderBy: 'receivedTimestamp DESC, uniqueId DESC',
        limit: limit,
      );
      final items = rows.map((json) => TrainRecord.fromDatabaseJson(json)).toList();
      final next = rows.length < limit
          ? null
          : PageCursor(
              (rows.last['receivedTimestamp'] as num).toInt(),
              rows.last['uniqueId'].toString(),
            );
      return DisplayPageResult(items.cast<Object>(), next);
    });
  }

  /// Paged merged search results: a group is a hit when any member matches.
  Future<List<Object>> searchDisplayPage({
    required String query,
    required int limit,
    required int offset,
    bool hideUngroupable = false,
  }) async {
    return _runInDbQueue(() async {
      final db = await database;
      final normalizedQuery = _normalizeSearchQuery(query);
      if (normalizedQuery == null) return <Object>[];

      final searchWhere = _buildSearchWhere(normalizedQuery);
      final scoreArgs = _searchRelevanceScoreArgs(normalizedQuery);

      try {
        return await DisplayGroupCache.fetchSearchPage(
          db,
          recordsTable: trainRecordsTable,
          searchWhereSql: searchWhere.whereSql,
          searchWhereArgs: searchWhere.whereArgs,
          searchScoreSql: _searchRelevanceScoreSql,
          searchScoreArgs: scoreArgs,
          limit: limit,
          offset: offset,
          hideUngroupable: hideUngroupable,
        );
      } catch (e) {
        developer.log('Merged FTS search failed, falling back to LIKE: $e',
            name: 'Database');
        final fallback = _buildSearchWhereFallback(normalizedQuery);
        return DisplayGroupCache.fetchSearchPage(
          db,
          recordsTable: trainRecordsTable,
          searchWhereSql: fallback.whereSql,
          searchWhereArgs: fallback.whereArgs,
          searchScoreSql: _searchRelevanceScoreSql,
          searchScoreArgs: scoreArgs,
          limit: limit,
          offset: offset,
          hideUngroupable: hideUngroupable,
        );
      }
    });
  }

  Future<int> countSearchDisplayGroups(
    String query, {
    bool hideUngroupable = false,
  }) async {
    return _runInDbQueue(() async {
      final db = await database;
      final normalizedQuery = _normalizeSearchQuery(query);
      if (normalizedQuery == null) return 0;

      final searchWhere = _buildSearchWhere(normalizedQuery);

      try {
        return await DisplayGroupCache.countSearchGroups(
          db,
          recordsTable: trainRecordsTable,
          searchWhereSql: searchWhere.whereSql,
          searchWhereArgs: searchWhere.whereArgs,
          hideUngroupable: hideUngroupable,
        );
      } catch (e) {
        final fallback = _buildSearchWhereFallback(normalizedQuery);
        return DisplayGroupCache.countSearchGroups(
          db,
          recordsTable: trainRecordsTable,
          searchWhereSql: fallback.whereSql,
          searchWhereArgs: fallback.whereArgs,
          hideUngroupable: hideUngroupable,
        );
      }
    });
  }

  /// The display item (single or merged group) containing [uniqueId].
  Future<Object?> displayItemContaining(String uniqueId) async {
    return _runInDbQueue(() async {
      final db = await database;
      return DisplayGroupCache.itemContaining(
        db,
        recordsTable: trainRecordsTable,
        uniqueId: uniqueId,
      );
    });
  }

  Future<List<TrainRecord>> getRecordsByUniqueIds(List<String> uniqueIds) async {
    if (uniqueIds.isEmpty) return [];
    return _runInDbQueue(() async {
      final db = await database;
      final placeholders = List.filled(uniqueIds.length, '?').join(',');
      final result = await db.rawQuery(
        '''
        SELECT * FROM $trainRecordsTable
        WHERE uniqueId IN ($placeholders)
        ORDER BY receivedTimestamp DESC
        ''',
        uniqueIds,
      );
      return result.map((json) => TrainRecord.fromDatabaseJson(json)).toList();
    });
  }

  Future<List<TrainRecord>> searchRecordsFuzzy({
    required String query,
    required int limit,
    required int offset,
  }) async {
    return _runInDbQueue(() async {
      final db = await database;
      final normalizedQuery = _normalizeSearchQuery(query);
      if (normalizedQuery == null) return <TrainRecord>[];

      final filters = _buildSearchFilters(normalizedQuery);
      final scoreArgs = _searchRelevanceScoreArgs(normalizedQuery);
      final queryArgs = [
        ...filters.whereArgs,
        ...scoreArgs,
        limit,
        offset,
      ];

      try {
        final result = await db.rawQuery('''
          SELECT r.* FROM $trainRecordsTable r
          WHERE r.isTimeOnly = 0 AND (${filters.whereClauses.join(' OR ')})
          ORDER BY $_searchOrderByClause
          LIMIT ? OFFSET ?
        ''', queryArgs);
        return result.map((json) => TrainRecord.fromDatabaseJson(json)).toList();
      } catch (e) {
        developer.log('FTS search failed, falling back to LIKE: $e', name: 'Database');
        final fallbackWhere = filters.charGapPattern != null
            ? 'searchText LIKE ? OR searchText LIKE ?'
            : 'searchText LIKE ?';
        final fallbackArgs = filters.charGapPattern != null
            ? [filters.containsPattern, filters.charGapPattern]
            : [filters.containsPattern];
        final fallbackScoreArgs = _searchRelevanceScoreArgs(normalizedQuery);
        final result = await db.rawQuery('''
          SELECT r.* FROM $trainRecordsTable r
          WHERE r.isTimeOnly = 0 AND ($fallbackWhere)
          ORDER BY $_searchOrderByClause
          LIMIT ? OFFSET ?
        ''', [...fallbackArgs, ...fallbackScoreArgs, limit, offset]);
        return result.map((json) => TrainRecord.fromDatabaseJson(json)).toList();
      }
    });
  }

  Future<int> countSearchResults(String query) async {
    return _runInDbQueue(() async {
      final db = await database;
      final normalizedQuery = _normalizeSearchQuery(query);
      if (normalizedQuery == null) return 0;

      final filters = _buildSearchFilters(normalizedQuery);

      try {
        final result = await db.rawQuery('''
          SELECT COUNT(DISTINCT r.uniqueId) AS cnt FROM $trainRecordsTable r
          WHERE r.isTimeOnly = 0 AND (${filters.whereClauses.join(' OR ')})
        ''', filters.whereArgs);
        return Sqflite.firstIntValue(result) ?? 0;
      } catch (e) {
        final fallbackWhere = filters.charGapPattern != null
            ? 'searchText LIKE ? OR searchText LIKE ?'
            : 'searchText LIKE ?';
        final fallbackArgs = filters.charGapPattern != null
            ? [filters.containsPattern, filters.charGapPattern]
            : [filters.containsPattern];
        final result = await db.rawQuery(
          'SELECT COUNT(*) AS cnt FROM $trainRecordsTable WHERE isTimeOnly = 0 AND ($fallbackWhere)',
          fallbackArgs,
        );
        return Sqflite.firstIntValue(result) ?? 0;
      }
    });
  }

  Future<TrainRecord?> getLatestRecord() async {
    return _runInDbQueue(() async {
      final db = await database;
      final result = await db.query(
        trainRecordsTable,
        orderBy: 'receivedTimestamp DESC',
        limit: 1,
      );
      if (result.isNotEmpty) {
        return TrainRecord.fromDatabaseJson(result.first);
      }
      return null;
    });
  }

  Future<Map<String, dynamic>?> _loadSettingsFromDb(Database db) async {
    try {
      final result = await db.query(
        appSettingsTable,
        where: 'id = 1',
      );
      if (result.isEmpty) return null;
      return result.first;
    } catch (e) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getAllSettings() async {
    if (_settingsCache != null) return _settingsCache;
    return _runInDbQueue(() async {
      if (_settingsCache != null) return _settingsCache;
      final db = await database;
      _settingsCache = await _loadSettingsFromDb(db);
      return _settingsCache;
    });
  }

  Future<int> updateSettings(Map<String, dynamic> settings) async {
    return _runInDbQueue(() async {
      final db = await database;
      final result = await db.update(
        appSettingsTable,
        settings,
        where: 'id = 1',
      );
      if (result > 0) {
        _settingsCache = await _loadSettingsFromDb(db);
        if (_settingsCache != null) {
          _notifySettingsChanged(_settingsCache!);
        }
      }
      return result;
    });
  }

  Future<int> setSetting(String key, dynamic value) async {
    return _runInDbQueue(() async {
      final db = await database;
      final result = await db.update(
        appSettingsTable,
        {key: value},
        where: 'id = 1',
      );
      if (result > 0) {
        _settingsCache = await _loadSettingsFromDb(db);
        if (_settingsCache != null) {
          _notifySettingsChanged(_settingsCache!);
        }
      }
      return result;
    });
  }

  Future<Map<String, dynamic>> getDatabaseInfo() async {
    final db = await database;
    final count = await getRecordCount();
    final settings = await getAllSettings();
    return {
      'databaseVersion': _databaseVersion,
      'trainRecordCount': count,
      'appSettings': settings,
      'path': db.path,
    };
  }

  Future<String?> backupDatabase() async {try {
      final db = await database;
      final directory = await getApplicationDocumentsDirectory();
      final originalPath = db.path;
      final backupDirectory = Directory(join(directory.path, 'backups'));
      if (!await backupDirectory.exists()) {
        await backupDirectory.create(recursive: true);
      }
      final backupPath = join(backupDirectory.path,
          'train_database_backup_${DateTime.now().millisecondsSinceEpoch}.db');
      await File(originalPath).copy(backupPath);
      return backupPath;
    } catch (e) {
      return null;
    }
  }

  Future<void> deleteRecords(List<String> uniqueIds) async {
    if (uniqueIds.isEmpty) return;
    await _runInDbQueue(() async {
      final db = await database;
      final batch = db.batch();
      for (String id in uniqueIds) {
        batch.delete(
          trainRecordsTable,
          where: 'uniqueId = ?',
          whereArgs: [id],
        );
        if (_fts5Available) {
          batch.delete(
            trainRecordsFtsTable,
            where: 'uniqueId = ?',
            whereArgs: [id],
          );
        }
      }
      await batch.commit(noResult: true);
      await DisplayGroupCache.removeRecords(
        db,
        recordsTable: trainRecordsTable,
        uniqueIds: uniqueIds,
      );
      _notifyRecordDeleted(uniqueIds);
    });
  }

  /// Rebuilds the merge-display cache from the current `train_records`.
  ///
  /// Use after a logic change to `MergeService.buildSummaryRecord` (which
  /// produces the cached `summaryJson`): existing cache rows still hold the
  /// old summaries, so merged cards keep showing stale field values until the
  /// cache is rebuilt. This regenerates every group + summary from scratch,
  /// then notifies settings listeners so the history list reloads with the
  /// fresh summaries.
  Future<void> rebuildMergeCache() async {
    await _runInDbQueue(() async {
      final db = await database;
      await DisplayGroupCache.rebuild(
        db,
        recordsTable: trainRecordsTable,
      );
    });
    final currentSettings = await getAllSettings();
    if (currentSettings != null) {
      _notifySettingsChanged(currentSettings);
    }
  }

  final List<Function(List<String>)> _recordDeleteListeners = [];

  final List<Function(Map<String, dynamic>)> _settingsListeners = [];

  StreamSubscription<void> onRecordDeleted(Function(List<String>) listener) {
    _recordDeleteListeners.add(listener);
    return _CallbackSubscription(() {
      _recordDeleteListeners.remove(listener);
    });
  }

  void _notifyRecordDeleted(List<String> deletedIds) {
    for (final listener in _recordDeleteListeners) {
      listener(deletedIds);
    }
  }

  StreamSubscription<void> onSettingsChanged(
      Function(Map<String, dynamic>) listener) {
    _settingsListeners.add(listener);
    return _CallbackSubscription(() {
      _settingsListeners.remove(listener);
    });
  }

  void _notifySettingsChanged(Map<String, dynamic> settings) {
    for (final listener in _settingsListeners) {
      listener(settings);
    }
  }

  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
      _settingsCache = null;
    }
  }

  // -------------------------------------------------------------------
  // Test-only hooks
  // -------------------------------------------------------------------

  /// Replaces the singleton with one backed by [db] (typically an in-memory
  /// FFI database opened in a test). Creates the full schema and seeds the
  /// default settings row so all production query methods work unchanged.
  @visibleForTesting
  static Future<void> overrideForTesting(Database db) async {
    final svc = DatabaseService._internal();
    svc._database = db;
    await svc._applyPragmas(db);
    await svc._onCreate(db, _databaseVersion);
    _testOverride = svc;
  }

  /// Clears a [overrideForTesting] override so subsequent tests get a fresh
  /// singleton (or the real one).
  @visibleForTesting
  static void resetForTesting() {
    _testOverride = null;
  }

  /// Number of merge-display groups currently cached, optionally excluding
  /// ungroupable singletons. Used by tests to assert pagination coverage.
  @visibleForTesting
  Future<int> countDisplayGroupsForTesting({bool hideUngroupable = false}) async {
    return _runInDbQueue(() async {
      final db = await database;
      final where = hideUngroupable ? 'WHERE isUngroupable = 0' : '';
      final r = await db.rawQuery(
        'SELECT COUNT(*) AS cnt FROM ${DisplayGroupCache.groupsTable} $where',
      );
      return Sqflite.firstIntValue(r) ?? 0;
    });
  }

  /// The total number of display items the feed should expose for the given
  /// settings: cache groups when merge is on, raw non-time-only records
  /// otherwise. Used by tests to assert that keyset pagination visits every
  /// item exactly once with no skips.
  @visibleForTesting
  Future<int> expectedDisplayTotalForTesting({
    required bool mergeEnabled,
    bool hideUngroupable = false,
  }) async {
    return _runInDbQueue(() async {
      final db = await database;
      if (mergeEnabled) {
        final where = hideUngroupable ? 'WHERE isUngroupable = 0' : '';
        final r = await db.rawQuery(
          'SELECT COUNT(*) AS cnt FROM ${DisplayGroupCache.groupsTable} $where',
        );
        return Sqflite.firstIntValue(r) ?? 0;
      }
      final r = await db.rawQuery(
        'SELECT COUNT(*) AS cnt FROM $trainRecordsTable '
        "WHERE isTimeOnly = 0 "
        "${hideUngroupable ? 'AND (trainKey IS NOT NULL OR locoKey IS NOT NULL) ' : ''}",
      );
      return Sqflite.firstIntValue(r) ?? 0;
    });
  }

  Future<String?> exportDataAsJson({String? customPath}) async {
    try {
      final records = <TrainRecord>[];
      var offset = 0;
      while (true) {
        final batch = await getRecordsBatch(
          limit: _exportBatchSize,
          offset: offset,
        );
        records.addAll(batch);
        if (batch.length < _exportBatchSize) break;
        offset += _exportBatchSize;
      }

      final exportData = {
        'records': records.map((r) => r.toDatabaseJson()).toList(),
      };

      final jsonString = jsonEncode(exportData);

      String filePath;
      if (customPath != null) {
        filePath = customPath;
      } else {
        final tempDir = Directory.systemTemp;
        final fileName =
            'LBJ_Console_${DateTime.now().year}${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().day.toString().padLeft(2, '0')}.json';
        filePath = join(tempDir.path, fileName);
      }

      await File(filePath).writeAsString(jsonString);
      return filePath;
    } catch (e) {
      return null;
    }
  }

  Future<bool> importDataFromJson(String filePath) async {
    try {
      final jsonString = await File(filePath).readAsString();
      final importData = jsonDecode(jsonString);
      final rawRecords = importData['records'] != null
          ? List<Map<String, dynamic>>.from(importData['records'] as List)
          : <Map<String, dynamic>>[];

      // Prepare insert-ready rows (searchText + derived columns) and the
      // merge-group payload in a single isolate pass so the UI thread stays
      // responsive and we avoid computing twice (once for the rows, once for
      // the cache rebuild).
      final payload = rawRecords.length > DisplayGroupCache.isolateRebuildThreshold
          ? await compute(prepareImportPayload, rawRecords)
          : prepareImportPayload(rawRecords);
      final rows = (payload['rows'] as List).cast<Map<String, dynamic>>();
      final groups = (payload['groups'] as List).cast<Map<String, dynamic>>();

      await _runInDbQueue(() async {
        final db = await database;
        await db.transaction((txn) async {
          await txn.delete(trainRecordsTable);
          await txn.delete(DisplayGroupCache.groupsTable);
          await txn.delete(DisplayGroupCache.membersTable);

          var batch = txn.batch();
          for (final row in rows) {
            batch.insert(trainRecordsTable, row,
                conflictAlgorithm: ConflictAlgorithm.replace);
          }
          await batch.commit(noResult: true);

          await DisplayGroupCache.applyPayload(txn, groups);

          // Rebuild FTS from the freshly inserted rows with a single
          // INSERT...SELECT instead of loading every row into Dart.
          if (_fts5Available) {
            await txn.delete(trainRecordsFtsTable);
            await txn.execute(
              'INSERT INTO $trainRecordsFtsTable(uniqueId, searchText) '
              'SELECT uniqueId, searchText FROM $trainRecordsTable',
            );
          }
        });
      });

      final currentSettings = await getAllSettings();
      if (currentSettings != null) {
        _notifySettingsChanged(currentSettings);
      }

      return true;
    } catch (e) {
      developer.log('importDataFromJson failed: $e', name: 'Database');
      return false;
    }
  }

  Future<bool> deleteExportFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }
}

class _CallbackSubscription implements StreamSubscription<void> {
  final void Function() _onCancel;
  bool _isCanceled = false;

  _CallbackSubscription(this._onCancel);

  @override
  Future<void> cancel() async {
    if (!_isCanceled) {
      _isCanceled = true;
      _onCancel();
    }
  }

  @override
  void onData(void Function(void data)? handleData) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void onError(Function? handleError) {}

  @override
  void pause([Future<void>? resumeSignal]) {}

  @override
  void resume() {}

  @override
  bool get isPaused => false;

  @override
  Future<E> asFuture<E>([E? futureValue]) => Future.value(futureValue);
}