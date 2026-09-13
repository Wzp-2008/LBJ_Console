import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:lbjconsole/models/map_state.dart';
import 'database_service.dart';
import 'dart:developer' as developer;

class MapStateService {
  static final MapStateService instance = MapStateService._internal();
  MapStateService._internal() {
    DatabaseService.instance.onRecordDeleted(_onRecordsDeleted);
  }

  static const String _tableName = 'record_map_states';

  final Map<String, MapState> _memoryCache = {};
  final Map<String, MapState> _pendingStates = {};
  final Map<String, Timer> _saveTimers = {};
  Future<void>? _tableReady;

  void _onRecordsDeleted(List<String> deletedIds) {
    if (deletedIds.isEmpty) return;
    for (final id in deletedIds) {
      unawaited(deleteMapState(getSingleRecordMapKey(id)));
    }
  }

  Future<void> _ensureTableExists() async {
    _tableReady ??= () async {
      final db = await DatabaseService.instance.database;
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $_tableName (
          key TEXT PRIMARY KEY,
          state TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');
    }();
    await _tableReady;
  }

  String getSingleRecordMapKey(String recordId) {
    return "${recordId}_record_map";
  }

  String getMergedRecordMapKey(String groupKey) {
    return "${groupKey}_group_map";
  }

  Future<void> saveMapState(String key, MapState state) async {
    try {
      _memoryCache[key] = state;

      await _ensureTableExists();
      final db = await DatabaseService.instance.database;

      await db.insert(_tableName, {
        'key': key,
        'state': jsonEncode(state.toJson()),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e, stack) {
      developer.log('保存地图状态失败：$e', name: 'MapStateService', stackTrace: stack);
    }
  }

  void saveMapStateDebounced(String key, MapState state) {
    _pendingStates[key] = state;
    _saveTimers[key]?.cancel();
    _saveTimers[key] = Timer(const Duration(milliseconds: 250), () {
      _saveTimers.remove(key);
      final pendingState = _pendingStates.remove(key);
      if (pendingState != null) {
        unawaited(saveMapState(key, pendingState));
      }
    });
  }

  Future<MapState?> getMapState(String key) async {
    if (_memoryCache.containsKey(key)) {
      return _memoryCache[key];
    }

    try {
      await _ensureTableExists();
      final db = await DatabaseService.instance.database;

      final result = await db.query(
        _tableName,
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );

      if (result.isNotEmpty) {
        final stateJson = jsonDecode(result.first['state'] as String);
        final state = MapState.fromJson(stateJson);
        _memoryCache[key] = state;
        return state;
      }
    } catch (e, stack) {
      developer.log('读取地图状态失败：$e', name: 'MapStateService', stackTrace: stack);
    }

    return null;
  }

  Future<void> deleteMapState(String key) async {
    _saveTimers.remove(key)?.cancel();
    _pendingStates.remove(key);
    _memoryCache.remove(key);

    try {
      await _ensureTableExists();
      final db = await DatabaseService.instance.database;
      await db.delete(_tableName, where: 'key = ?', whereArgs: [key]);
    } catch (e, stack) {
      developer.log('删除地图状态失败：$e', name: 'MapStateService', stackTrace: stack);
    }
  }

  Future<void> clearAllMapStates() async {
    for (final timer in _saveTimers.values) {
      timer.cancel();
    }
    _saveTimers.clear();
    _pendingStates.clear();
    _memoryCache.clear();

    try {
      await _ensureTableExists();
      final db = await DatabaseService.instance.database;
      await db.delete(_tableName);
    } catch (e, stack) {
      developer.log('清理地图状态失败：$e', name: 'MapStateService', stackTrace: stack);
    }
  }
}
