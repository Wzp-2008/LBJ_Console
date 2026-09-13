import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'dart:io';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:lbjconsole/models/train_record.dart';
import 'package:lbjconsole/models/firmware_board.dart';
import 'package:lbjconsole/services/csv_import_service.dart';
import 'package:lbjconsole/services/display_group_cache.dart';
import 'package:lbjconsole/services/sqflite_initializer.dart';
import 'package:lbjconsole/util/csv_parser.dart';

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
  static const _databaseVersion = 20;

  static const String trainRecordsTable = 'train_records';
  static const String trainRecordsFtsTable = 'train_records_fts';
  static const String appSettingsTable = 'app_settings';
  static const String deviceBoardHistoryTable = 'device_board_history';
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
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
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

    // Safety net for interrupted writes/migrations.  An empty-cache check
    // alone cannot detect orphaned members or stale group counts.
    if (await DisplayGroupCache.needsRebuild(
      db,
      recordsTable: trainRecordsTable,
    )) {
      await DisplayGroupCache.rebuild(db, recordsTable: trainRecordsTable);
    }

    return db;
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    developer.log(
      'Database upgrading from $oldVersion to $newVersion',
      name: 'Database',
    );

    if (oldVersion < 6) {
      await db.execute(
        'ALTER TABLE $appSettingsTable ADD COLUMN hideUngroupableRecords INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 10) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_records_timestamp ON $trainRecordsTable(timestamp)',
      );
    }
    if (oldVersion < 11) {
      await _ensureSearchTextColumn(db);
    }
    if (oldVersion < 12) {
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
        'CREATE INDEX IF NOT EXISTS idx_mdg_cursor ON ${DisplayGroupCache.groupsTable}(latestReceivedTimestamp DESC, groupId ASC)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_records_cursor ON $trainRecordsTable(receivedTimestamp DESC, uniqueId DESC)',
      );
    }
    if (oldVersion < 18) {
      await db.execute('DROP INDEX IF EXISTS idx_records_received');
      await db.execute('DROP INDEX IF EXISTS idx_mdg_latest');
    }
    if (oldVersion < 20) {
      await _createDeviceBoardHistoryTable(db);
    }
  }

  Future<void> _createSettingsTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $appSettingsTable (
        id INTEGER PRIMARY KEY,
        specifiedDeviceAddress TEXT,
        backgroundServiceEnabled INTEGER NOT NULL DEFAULT 0,
        notificationEnabled INTEGER NOT NULL DEFAULT 0,
        mergeRecordsEnabled INTEGER NOT NULL DEFAULT 0,
        hideUngroupableRecords INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  Future<void> _createDeviceBoardHistoryTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $deviceBoardHistoryTable (
        deviceAddress TEXT PRIMARY KEY,
        board TEXT NOT NULL
      )
    ''');
  }

  Map<String, dynamic> _defaultSettings() {
    return {
      'id': 1,
      'specifiedDeviceAddress': null,
      'backgroundServiceEnabled': 0,
      'notificationEnabled': 0,
      'mergeRecordsEnabled': 0,
      'hideUngroupableRecords': 0,
    };
  }

  Future<void> _ensureDerivedColumns(Database db) async {
    if (!await _columnExists(db, trainRecordsTable, 'isTimeOnly')) {
      await db.execute(
        'ALTER TABLE $trainRecordsTable ADD COLUMN isTimeOnly INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!await _columnExists(db, trainRecordsTable, 'trainKey')) {
      await db.execute(
        'ALTER TABLE $trainRecordsTable ADD COLUMN trainKey TEXT',
      );
    }
    if (!await _columnExists(db, trainRecordsTable, 'locoKey')) {
      await db.execute(
        'ALTER TABLE $trainRecordsTable ADD COLUMN locoKey TEXT',
      );
    }
    await _backfillDerivedColumns(db);
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_trainkey ON $trainRecordsTable(trainKey)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_locokey ON $trainRecordsTable(locoKey)',
    );
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

  ({String whereSql, List<dynamic> whereArgs}) _buildSearchWhere(
    String normalizedQuery,
  ) {
    final filters = _buildSearchFilters(normalizedQuery);
    return (
      whereSql: filters.whereClauses.map((c) => '($c)').join(' OR '),
      whereArgs: filters.whereArgs,
    );
  }

  ({String whereSql, List<dynamic> whereArgs}) _buildSearchWhereFallback(
    String normalizedQuery,
  ) {
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
    await db.execute(
      'INSERT INTO $trainRecordsFtsTable(uniqueId, searchText) '
      'SELECT uniqueId, searchText FROM $trainRecordsTable',
    );
  }

  Future<void> _syncFtsUpsert(
    DatabaseExecutor db,
    String uniqueId,
    String searchText,
  ) async {
    if (!_fts5Available) return;
    await db.delete(
      trainRecordsFtsTable,
      where: 'uniqueId = ?',
      whereArgs: [uniqueId],
    );
    await db.insert(trainRecordsFtsTable, {
      'uniqueId': uniqueId,
      'searchText': searchText,
    });
  }

  Future<void> _syncFtsDelete(DatabaseExecutor db, String uniqueId) async {
    if (!_fts5Available) return;
    await db.delete(
      trainRecordsFtsTable,
      where: 'uniqueId = ?',
      whereArgs: [uniqueId],
    );
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
  })
  _buildSearchFilters(String normalizedQuery) {
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

    whereClauses.add("replace(lower(r.lbjClass || r.train), '-', '') LIKE ?");
    whereArgs.add(containsPattern);

    whereClauses.add("replace(lower(r.route), '-', '') LIKE ?");
    whereArgs.add(containsPattern);

    whereClauses.add("replace(lower(r.positionInfo), '-', '') LIKE ?");
    whereArgs.add(containsPattern);

    if (!_isTrainLikeQuery(normalizedQuery)) {
      whereClauses.add("replace(lower(r.locoType || r.loco), '-', '') LIKE ?");
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

    await _createSettingsTable(db);
    await db.insert(appSettingsTable, _defaultSettings());
    await _createDeviceBoardHistoryTable(db);

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_timestamp ON $trainRecordsTable(timestamp)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_search ON $trainRecordsTable(searchText)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_cursor ON $trainRecordsTable(receivedTimestamp DESC, uniqueId DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_trainkey ON $trainRecordsTable(trainKey)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_locokey ON $trainRecordsTable(locoKey)',
    );
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
      return db.transaction((txn) async {
        // A replace can change the grouping keys. Remove the old membership
        // before inserting the new row so the previous group is recomputed.
        await DisplayGroupCache.removeRecords(
          txn,
          recordsTable: trainRecordsTable,
          uniqueIds: [record.uniqueId],
        );
        final result = await txn.insert(
          trainRecordsTable,
          json,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await _syncFtsUpsert(txn, record.uniqueId, record.searchText);
        await DisplayGroupCache.applyNewRecord(
          txn,
          recordsTable: trainRecordsTable,
          record: record,
        );
        return result;
      });
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

  Future<int> deleteRecord(String uniqueId) async {
    return _runInDbQueue(() async {
      final db = await database;
      final result = await db.transaction((txn) async {
        final deleted = await txn.delete(
          trainRecordsTable,
          where: 'uniqueId = ?',
          whereArgs: [uniqueId],
        );
        if (deleted > 0) {
          await _syncFtsDelete(txn, uniqueId);
          await DisplayGroupCache.removeRecords(
            txn,
            recordsTable: trainRecordsTable,
            uniqueIds: [uniqueId],
          );
        }
        return deleted;
      });

      if (result > 0) {
        _notifyRecordDeleted([uniqueId]);
      }

      return result;
    });
  }

  Future<int> deleteAllRecords() async {
    return _runInDbQueue(() async {
      final db = await database;
      final result = await db.transaction((txn) async {
        final deleted = await txn.delete(trainRecordsTable);
        if (_fts5Available) {
          await txn.delete(trainRecordsFtsTable);
        }
        await DisplayGroupCache.clear(txn);
        return deleted;
      });

      if (result > 0) {
        _notifyRecordDeleted([]);
      }

      return result;
    });
  }

  Future<int> getRecordCount() async {
    return _runInDbQueue(() async {
      final db = await database;
      final result = await db.rawQuery(
        'SELECT COUNT(*) FROM $trainRecordsTable',
      );
      return Sqflite.firstIntValue(result) ?? 0;
    });
  }

  Future<List<TrainRecord>> getRecordsBatch({
    required int limit,
    required int offset,
  }) async {
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
      final items = rows
          .map((json) => TrainRecord.fromDatabaseJson(json))
          .toList();
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
        developer.log(
          'Merged FTS search failed, falling back to LIKE: $e',
          name: 'Database',
        );
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

  Future<List<TrainRecord>> getRecordsByUniqueIds(
    List<String> uniqueIds,
  ) async {
    if (uniqueIds.isEmpty) return [];
    return _runInDbQueue(() async {
      final db = await database;
      final records = <TrainRecord>[];
      for (final chunk in DisplayGroupCache.chunks(uniqueIds)) {
        final placeholders = List.filled(chunk.length, '?').join(',');
        final rows = await db.rawQuery(
          'SELECT * FROM $trainRecordsTable WHERE uniqueId IN ($placeholders)',
          chunk,
        );
        records.addAll(rows.map(TrainRecord.fromDatabaseJson));
      }
      records.sort(
        (a, b) => b.receivedTimestamp.compareTo(a.receivedTimestamp),
      );
      return records;
    });
  }

  Future<List<TrainRecord>> searchRecordsFuzzy({
    required String query,
    required int limit,
    required int offset,
    bool hideUngroupable = false,
  }) async {
    return _runInDbQueue(() async {
      final db = await database;
      final normalizedQuery = _normalizeSearchQuery(query);
      if (normalizedQuery == null) return <TrainRecord>[];

      final filters = _buildSearchFilters(normalizedQuery);
      final scoreArgs = _searchRelevanceScoreArgs(normalizedQuery);
      final baseWhere = <String>['r.isTimeOnly = 0'];
      if (hideUngroupable) {
        baseWhere.add('(r.trainKey IS NOT NULL OR r.locoKey IS NOT NULL)');
      }
      final queryArgs = [...filters.whereArgs, ...scoreArgs, limit, offset];

      try {
        final result = await db.rawQuery('''
          SELECT r.* FROM $trainRecordsTable r
          WHERE ${baseWhere.join(' AND ')}
            AND (${filters.whereClauses.join(' OR ')})
          ORDER BY $_searchOrderByClause
          LIMIT ? OFFSET ?
        ''', queryArgs);
        return result
            .map((json) => TrainRecord.fromDatabaseJson(json))
            .toList();
      } catch (e) {
        developer.log(
          'FTS search failed, falling back to LIKE: $e',
          name: 'Database',
        );
        final fallback = _buildSearchWhereFallback(normalizedQuery);
        final result = await db.rawQuery(
          '''
          SELECT r.* FROM $trainRecordsTable r
          WHERE ${baseWhere.join(' AND ')} AND (${fallback.whereSql})
          ORDER BY $_searchOrderByClause
          LIMIT ? OFFSET ?
        ''',
          [...fallback.whereArgs, ...scoreArgs, limit, offset],
        );
        return result
            .map((json) => TrainRecord.fromDatabaseJson(json))
            .toList();
      }
    });
  }

  Future<int> countSearchResults(
    String query, {
    bool hideUngroupable = false,
  }) async {
    return _runInDbQueue(() async {
      final db = await database;
      final normalizedQuery = _normalizeSearchQuery(query);
      if (normalizedQuery == null) return 0;

      final filters = _buildSearchFilters(normalizedQuery);
      final baseWhere = <String>['r.isTimeOnly = 0'];
      if (hideUngroupable) {
        baseWhere.add('(r.trainKey IS NOT NULL OR r.locoKey IS NOT NULL)');
      }

      try {
        final result = await db.rawQuery('''
          SELECT COUNT(DISTINCT r.uniqueId) AS cnt FROM $trainRecordsTable r
          WHERE ${baseWhere.join(' AND ')}
            AND (${filters.whereClauses.join(' OR ')})
        ''', filters.whereArgs);
        return Sqflite.firstIntValue(result) ?? 0;
      } catch (e) {
        final fallback = _buildSearchWhereFallback(normalizedQuery);
        final result = await db.rawQuery(
          'SELECT COUNT(*) AS cnt FROM $trainRecordsTable r '
          'WHERE ${baseWhere.join(' AND ')} AND (${fallback.whereSql})',
          fallback.whereArgs,
        );
        return Sqflite.firstIntValue(result) ?? 0;
      }
    });
  }

  Future<Map<String, dynamic>?> _loadSettingsFromDb(Database db) async {
    try {
      final result = await db.query(appSettingsTable, where: 'id = 1');
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
    return updateSettings({key: value});
  }

  Future<FirmwareBoard?> getDeviceBoard(String address) {
    final normalized = normalizeBluetoothAddress(address);
    return _runInDbQueue(() async {
      final db = await database;
      final rows = await db.query(
        deviceBoardHistoryTable,
        columns: const ['board'],
        where: 'deviceAddress = ?',
        whereArgs: [normalized],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return FirmwareBoard.fromWireValue(rows.first['board']);
    });
  }

  Future<void> setDeviceBoard(String address, FirmwareBoard board) {
    final normalized = normalizeBluetoothAddress(address);
    return _runInDbQueue(() async {
      final db = await database;
      await db.insert(deviceBoardHistoryTable, {
        'deviceAddress': normalized,
        'board': board.wireName,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> clearDeviceBoardHistory() {
    return _runInDbQueue(() async {
      final db = await database;
      await db.delete(deviceBoardHistoryTable);
    });
  }

  Future<void> deleteRecords(List<String> uniqueIds) async {
    if (uniqueIds.isEmpty) return;
    await _runInDbQueue(() async {
      final db = await database;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final id in uniqueIds) {
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
          txn,
          recordsTable: trainRecordsTable,
          uniqueIds: uniqueIds,
        );
      });
      _notifyRecordDeleted(uniqueIds);
    });
  }

  /// Rebuilds the merge-display cache from the current `train_records`.
  ///
  /// Use after a logic change to `MergeService.buildSummaryRecord` or to
  /// `TrainRecord.trainKey`/`locoKey` (which produce the cached `summaryJson`
  /// and the persisted `trainKey`/`locoKey`/`isTimeOnly` columns): existing
  /// cache rows still hold the old summaries, and existing `train_records`
  /// rows still hold the old derived columns, so merged cards keep showing
  /// stale field values and garbled keys (e.g. `(9(99`) keep records grouped
  /// / visible until refreshed. This regenerates the derived columns from
  /// scratch, then every group + summary, and notifies settings listeners so
  /// the history list reloads with the fresh data.
  Future<void> rebuildMergeCache() async {
    await _runInDbQueue(() async {
      final db = await database;
      await _backfillDerivedColumns(db);
      await DisplayGroupCache.rebuild(db, recordsTable: trainRecordsTable);
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
    Function(Map<String, dynamic>) listener,
  ) {
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
  Future<int> countDisplayGroupsForTesting({
    bool hideUngroupable = false,
  }) async {
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
    if (mergeEnabled) {
      return countDisplayGroupsForTesting(hideUngroupable: hideUngroupable);
    }
    return _runInDbQueue(() async {
      final db = await database;
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
      final decoded = jsonDecode(jsonString);
      if (decoded is! Map) {
        throw const FormatException('备份根节点必须是 JSON 对象');
      }
      final recordsValue = decoded['records'];
      if (recordsValue is! List) {
        throw const FormatException('备份必须包含 records 数组');
      }
      final rawRecords = recordsValue.map<Map<String, dynamic>>((value) {
        if (value is! Map) {
          throw const FormatException('records 中包含非对象元素');
        }
        return Map<String, dynamic>.from(value);
      }).toList();
      return await importRawRecords(rawRecords);
    } catch (e) {
      developer.log('importDataFromJson failed: $e', name: 'Database');
      return false;
    }
  }

  /// Replace all records and merge groups with [rawRecords] (raw JSON-style
  /// maps as produced by `csv_json.py` / the live receivers). Shared by the
  /// JSON file import and the CSV-from-drive import so both flow through the
  /// same isolate prepare + single-transaction insert + FTS rebuild.
  Future<bool> importRawRecords(List<Map<String, dynamic>> rawRecords) async {
    try {
      _validateImportRecords(rawRecords);
      // Prepare insert-ready rows (searchText + derived columns) and the
      // merge-group payload in a single isolate pass so the UI thread stays
      // responsive and we avoid computing twice (once for the rows, once for
      // the cache rebuild).
      final payload =
          rawRecords.length > DisplayGroupCache.isolateRebuildThreshold
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
            batch.insert(
              trainRecordsTable,
              row,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
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
      developer.log('importRawRecords failed: $e', name: 'Database');
      return false;
    }
  }

  void _validateImportRecords(List<Map<String, dynamic>> records) {
    final seenIds = <String>{};
    const requiredFields = <String, List<String>>{
      'uniqueId': ['uniqueId', 'unique_id'],
      'timestamp': ['timestamp'],
      'receivedTimestamp': ['receivedTimestamp', 'received_timestamp'],
      'train': ['train'],
      'direction': ['direction', 'dir'],
      'speed': ['speed'],
      'position': ['position', 'pos'],
      'time': ['time'],
      'loco': ['loco'],
      'locoType': ['locoType', 'loco_type'],
      'lbjClass': ['lbjClass', 'lbj_class'],
      'route': ['route'],
      'positionInfo': ['positionInfo', 'position_info'],
      'rssi': ['rssi'],
    };
    for (var index = 0; index < records.length; index++) {
      final record = records[index];
      final missing = requiredFields.entries
          .where((entry) => !entry.value.any(record.containsKey))
          .map((entry) => entry.key)
          .toList();
      if (missing.isNotEmpty) {
        throw FormatException('第 ${index + 1} 条记录缺少字段：${missing.join(', ')}');
      }
      final parsed = TrainRecord.fromJson(record);
      if (parsed.uniqueId.isEmpty) {
        throw FormatException('第 ${index + 1} 条记录的 uniqueId 不能为空');
      }
      if (!seenIds.add(parsed.uniqueId)) {
        throw FormatException('记录 uniqueId 重复：${parsed.uniqueId}');
      }
    }
  }

  /// Read every `.csv` file in `<driveLetter>:\CSVTEST`, convert each row to a
  /// train record (porting `csv_json.py`'s parsing logic off the UI thread via
  /// [parseCsvFilesToRecords]), and import the result — replacing all existing
  /// data. Windows only (the `X:\CSVTEST` path convention is Windows-specific).
  /// Returns a [CsvImportResult] with counts and a user-facing message.
  Future<CsvImportResult> importCsvFromDrive(String driveLetter) async {
    final letter = driveLetter.trim().toUpperCase();
    if (letter.isEmpty) {
      return const CsvImportResult(success: false, message: '未选择盘符');
    }
    final dirPath = '$letter:\\CSVTEST';
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      return CsvImportResult(success: false, message: '目录不存在：$dirPath');
    }

    final csvFiles = <String>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.csv')) {
          csvFiles.add(entity.path);
        }
      }
    } catch (e) {
      return CsvImportResult(success: false, message: '读取目录失败：$e');
    }
    if (csvFiles.isEmpty) {
      return CsvImportResult(success: false, message: '未在 $dirPath 找到 CSV 文件');
    }
    csvFiles.sort();

    // Loaded on the main isolate: worker isolates cannot touch rootBundle.
    final locoTypeMap = await _loadLocoTypeMap();
    final Map<String, dynamic> payload;
    try {
      payload = await compute<Map<String, dynamic>, Map<String, dynamic>>(
        parseCsvFilesToRecords,
        <String, dynamic>{'files': csvFiles, 'locoTypeMap': locoTypeMap},
      );
    } catch (e) {
      return CsvImportResult(success: false, message: '解析 CSV 失败：$e');
    }
    final records = (payload['records'] as List).cast<Map<String, dynamic>>();

    if (records.isEmpty) {
      return CsvImportResult(
        success: false,
        fileCount: csvFiles.length,
        message: 'CSV 文件中未解析出有效记录',
      );
    }

    final ok = await importRawRecords(records);
    return CsvImportResult(
      success: ok,
      fileCount: csvFiles.length,
      recordCount: records.length,
      message: ok ? '导入 ${records.length} 条记录（${csvFiles.length} 个文件）' : '导入失败',
    );
  }

  /// Load the `loco_type_info.csv` asset into a code→name map. Standalone
  /// (rather than reusing the `LocoTypeUtil` singleton) so the result can be
  /// handed to the CSV-parse isolate without an init-order race.
  Future<Map<String, String>> _loadLocoTypeMap() async {
    try {
      final csv = await rootBundle.loadString('assets/loco_type_info.csv');
      return parseLocoTypeMap(csv);
    } catch (e) {
      return {};
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
