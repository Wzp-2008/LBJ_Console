import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:lbjconsole/models/merged_record.dart';
import 'package:lbjconsole/models/train_record.dart';
import 'package:lbjconsole/services/merge_service.dart' show MergeService;
import 'package:sqflite/sqflite.dart';

/// Opaque cursor for keyset pagination over the display list.
///
/// `(timestamp, id)` is the position of the last item on a page; the next
/// page fetches items strictly *after* this position in the page's total
/// order. Because new live records always land above the cursor (they are
/// newer), paging towards older items never re-visits an already-shown item
/// — this is what fixes the old offset/limit "list never changes / shows no
/// data" bug on a live stream.
class PageCursor {
  final int timestamp;
  final String id;
  const PageCursor(this.timestamp, this.id);
}

/// One page of display items plus the cursor for fetching the next page.
/// [nextCursor] is null when this was the last (short) page.
class DisplayPageResult {
  final List<Object> items;
  final PageCursor? nextCursor;
  const DisplayPageResult(this.items, this.nextCursor);
}

/// Pre-computed merge groups in SQLite.
///
/// The merge rule is fixed: records sharing a train number OR a locomotive
/// number are grouped when matching-key observations are at most 1 hour
/// apart. Transitive connections join groups, but unrelated keys do not
/// extend the lifetime of an old train/locomotive key.
/// Time-only records never enter the cache. The cache is updated
/// incrementally on insert/delete; a full rebuild only happens on data
/// import or schema migration.
class DisplayGroupCache {
  static const String groupsTable = 'merge_display_groups';
  static const String membersTable = 'merge_display_members';
  static const Duration mergeWindow = Duration(hours: 1);
  static const int isolateRebuildThreshold = 500;
  static const String _idSep = '\x1f';

  static Future<void> ensureTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $groupsTable (
        groupId TEXT PRIMARY KEY,
        latestReceivedTimestamp INTEGER NOT NULL,
        memberCount INTEGER NOT NULL,
        representativeUniqueId TEXT NOT NULL,
        summaryJson TEXT NOT NULL DEFAULT '',
        isUngroupable INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_mdg_sort
      ON $groupsTable(isUngroupable, latestReceivedTimestamp DESC)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_mdg_cursor
      ON $groupsTable(latestReceivedTimestamp DESC, groupId ASC)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $membersTable (
        uniqueId TEXT PRIMARY KEY,
        groupId TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_mdm_group
      ON $membersTable(groupId)
    ''');
  }

  /// Drops the legacy settingsKey-based cache tables (pre-v15 schema).
  static Future<void> dropLegacyTables(DatabaseExecutor db) async {
    await db.execute('DROP TABLE IF EXISTS $groupsTable');
    await db.execute('DROP TABLE IF EXISTS $membersTable');
  }

  static Future<bool> isEmpty(DatabaseExecutor db) async {
    final row = await db.rawQuery('SELECT 1 FROM $groupsTable LIMIT 1');
    return row.isEmpty;
  }

  /// Returns true when the cache is incomplete or its denormalized counts no
  /// longer agree with the source records.  Checking only whether the cache
  /// is empty misses interrupted writes and orphaned members.
  static Future<bool> needsRebuild(
    DatabaseExecutor db, {
    required String recordsTable,
  }) async {
    final orphanMember = await db.rawQuery('''
      SELECT 1 FROM $membersTable m
      LEFT JOIN $recordsTable r ON r.uniqueId = m.uniqueId
      WHERE r.uniqueId IS NULL LIMIT 1
    ''');
    if (orphanMember.isNotEmpty) return true;

    final orphanGroup = await db.rawQuery('''
      SELECT 1 FROM $groupsTable g
      LEFT JOIN $recordsTable r ON r.uniqueId = g.representativeUniqueId
      WHERE r.uniqueId IS NULL LIMIT 1
    ''');
    if (orphanGroup.isNotEmpty) return true;

    final counts = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM $recordsTable WHERE isTimeOnly = 0) AS records_count,
        (SELECT COUNT(*) FROM $membersTable) AS members_count,
        (SELECT COUNT(*) FROM $groupsTable) AS groups_count
    ''');
    final count = counts.single;
    final recordCount = (count['records_count'] as num).toInt();
    final memberCount = (count['members_count'] as num).toInt();
    final groupCount = (count['groups_count'] as num).toInt();
    if (recordCount != memberCount ||
        (recordCount > 0 && groupCount == 0) ||
        (recordCount == 0 && groupCount != 0)) {
      return true;
    }

    final badGroup = await db.rawQuery('''
      SELECT g.groupId
      FROM $groupsTable g
      LEFT JOIN $membersTable m ON m.groupId = g.groupId
      GROUP BY g.groupId, g.memberCount
      HAVING COUNT(m.uniqueId) != g.memberCount
      LIMIT 1
    ''');
    return badGroup.isNotEmpty;
  }

  // ---------------------------------------------------------------------
  // Full rebuild
  // ---------------------------------------------------------------------

  /// Rebuilds the whole cache from [recordsTable]. Runs the grouping in an
  /// isolate for large datasets so the UI thread stays responsive.
  static Future<void> rebuild(
    Database db, {
    required String recordsTable,
  }) async {
    final rows = await db.query(recordsTable, where: 'isTimeOnly = 0');
    final plainRows = rows.map((r) => Map<String, dynamic>.from(r)).toList();

    final payload = plainRows.length > isolateRebuildThreshold
        ? await compute(buildDisplayGroupsPayload, plainRows)
        : buildDisplayGroupsPayload(plainRows);

    await db.transaction((txn) => applyPayload(txn, payload));
  }

  /// Replaces the whole cache with [payload] inside [txn]. Used by [rebuild]
  /// and by the JSON import path (which prepares the payload in an isolate
  /// together with the insert-ready record rows).
  static Future<void> applyPayload(
    DatabaseExecutor txn,
    List<Map<String, dynamic>> payload,
  ) async {
    await txn.delete(groupsTable);
    await txn.delete(membersTable);
    var batch = txn.batch();
    var pending = 0;
    for (final group in payload) {
      _addGroupToBatch(batch, group);
      if (++pending >= 400) {
        await batch.commit(noResult: true);
        batch = txn.batch();
        pending = 0;
      }
    }
    if (pending > 0) {
      await batch.commit(noResult: true);
    }
  }

  static void _addGroupToBatch(Batch batch, Map<String, dynamic> group) {
    final groupId = group['groupId'] as String;
    batch.insert(groupsTable, {
      'groupId': groupId,
      'latestReceivedTimestamp': group['latestReceivedTimestamp'],
      'memberCount': group['memberCount'],
      'representativeUniqueId': group['representativeUniqueId'],
      'summaryJson': group['summaryJson'],
      'isUngroupable': group['isUngroupable'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    for (final id in group['memberIds'] as List) {
      batch.insert(membersTable, {
        'uniqueId': id,
        'groupId': groupId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  // ---------------------------------------------------------------------
  // Incremental updates
  // ---------------------------------------------------------------------

  /// Incrementally folds a newly inserted record into the cache.
  static Future<void> applyNewRecord(
    DatabaseExecutor db, {
    required String recordsTable,
    required TrainRecord record,
  }) async {
    if (record.isTimeOnly) return;

    final ts = record.receivedTimestamp.millisecondsSinceEpoch;
    final windowMs = mergeWindow.inMilliseconds;
    final trainKey = record.trainKey;
    final locoKey = record.locoKey;

    var candidateIds = <String>[];
    if (trainKey != null || locoKey != null) {
      final keyClauses = <String>[];
      final keyArgs = <dynamic>[];
      if (trainKey != null) {
        keyClauses.add('r.trainKey = ?');
        keyArgs.add(trainKey);
      }
      if (locoKey != null) {
        keyClauses.add('r.locoKey = ?');
        keyArgs.add(locoKey);
      }
      final rows = await db.rawQuery(
        '''
        SELECT DISTINCT g.groupId
        FROM $recordsTable r
        INNER JOIN $membersTable m ON m.uniqueId = r.uniqueId
        INNER JOIN $groupsTable g ON g.groupId = m.groupId
        WHERE (${keyClauses.join(' OR ')})
          AND r.receivedTimestamp BETWEEN ? AND ?
        ''',
        [...keyArgs, ts - windowMs, ts + windowMs],
      );
      candidateIds = rows.map((row) => row['groupId'].toString()).toList();
    }

    if (candidateIds.isEmpty) {
      await _insertSingleGroup(db, record);
      return;
    }

    // Preserve the surviving groupId so the card identity (groupKey) stays
    // stable when an out-of-order (older) record folds into the group. The
    // lexicographically smallest candidate groupId equals the oldest
    // member's uniqueId, which is what a full rebuild would also pick — so
    // incremental and rebuild paths agree in the common (in-order) case,
    // and the incremental path is additionally stable on late arrivals.
    final survivor = candidateIds.reduce((a, b) => a.compareTo(b) < 0 ? a : b);

    // Live reception normally appends to one group. Its cached summary is a
    // sufficient accumulator: do not deserialize and rewrite every member.
    if (candidateIds.length == 1) {
      final rows = await db.query(
        groupsTable,
        where: 'groupId = ?',
        whereArgs: [survivor],
      );
      final group = rows.single;
      final latestTs = (group['latestReceivedTimestamp'] as num).toInt();
      final latestId = group['representativeUniqueId'] as String;
      if (ts > latestTs ||
          (ts == latestTs && record.uniqueId.compareTo(latestId) > 0)) {
        final cached = group['summaryJson'] as String;
        final previous = cached.isNotEmpty
            ? TrainRecord.fromDatabaseJson(
                jsonDecode(cached) as Map<String, dynamic>,
              )
            : TrainRecord.fromDatabaseJson(
                (await db.query(
                  recordsTable,
                  where: 'uniqueId = ?',
                  whereArgs: [latestId],
                )).single,
              );
        final summary = MergeService.buildSummaryRecord([record, previous]);
        await db.update(
          groupsTable,
          {
            'latestReceivedTimestamp': ts,
            'representativeUniqueId': record.uniqueId,
            'memberCount': (group['memberCount'] as num).toInt() + 1,
            'summaryJson': jsonEncode(summary.toTransferJson()),
            'isUngroupable': 0,
          },
          where: 'groupId = ?',
          whereArgs: [survivor],
        );
        await db.insert(membersTable, {
          'uniqueId': record.uniqueId,
          'groupId': survivor,
        });
        return;
      }
    }

    final placeholders = List.filled(candidateIds.length, '?').join(',');
    final memberRows = await db.rawQuery('''
        SELECT r.* FROM $membersTable m
        INNER JOIN $recordsTable r ON r.uniqueId = m.uniqueId
        WHERE m.groupId IN ($placeholders)
        ''', candidateIds);
    final members = <String, TrainRecord>{
      for (final row in memberRows)
        row['uniqueId'].toString(): TrainRecord.fromDatabaseJson(row),
      record.uniqueId: record,
    };

    await db.delete(
      groupsTable,
      where: 'groupId IN ($placeholders)',
      whereArgs: candidateIds,
    );
    await db.delete(
      membersTable,
      where: 'groupId IN ($placeholders)',
      whereArgs: candidateIds,
    );

    await _insertGroup(db, members.values.toList(), preserveGroupId: survivor);
  }

  /// Incrementally removes deleted records from the cache; affected groups
  /// are recomputed from their remaining members.
  static Future<void> removeRecords(
    DatabaseExecutor db, {
    required String recordsTable,
    required List<String> uniqueIds,
  }) async {
    if (uniqueIds.isEmpty) return;

    final groupIds = <String>{};
    for (final chunk in chunks(uniqueIds)) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      final groupRows = await db.rawQuery(
        'SELECT DISTINCT groupId FROM $membersTable WHERE uniqueId IN ($placeholders)',
        chunk,
      );
      groupIds.addAll(groupRows.map((row) => row['groupId'].toString()));
    }
    if (groupIds.isEmpty) return;

    for (final chunk in chunks(uniqueIds)) {
      await db.delete(
        membersTable,
        where: 'uniqueId IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
    }

    final groupIdList = groupIds.toList();
    final remainingByGroup = <String, List<TrainRecord>>{};
    for (final chunk in chunks(groupIdList)) {
      final groupPlaceholders = List.filled(chunk.length, '?').join(',');
      final memberRows = await db.rawQuery('''
        SELECT m.groupId AS member_group_id, r.* FROM $membersTable m
        INNER JOIN $recordsTable r ON r.uniqueId = m.uniqueId
        WHERE m.groupId IN ($groupPlaceholders)
        ''', chunk);
      for (final row in memberRows) {
        remainingByGroup
            .putIfAbsent(row['member_group_id'] as String, () => [])
            .add(TrainRecord.fromDatabaseJson(row));
      }
    }

    for (final chunk in chunks(groupIdList)) {
      await db.delete(
        groupsTable,
        where: 'groupId IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
      await db.delete(
        membersTable,
        where: 'groupId IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
    }

    for (final entry in remainingByGroup.entries) {
      final payload = groupRecordsIntoPayload(entry.value);
      // Keep identity when deletion leaves a connected group. A removed
      // bridge can create multiple components, each with its own identity.
      if (payload.length == 1) payload.single['groupId'] = entry.key;
      for (final group in payload) {
        await _insertPayload(db, group);
      }
    }
  }

  static Future<void> clear(DatabaseExecutor db) async {
    await db.delete(groupsTable);
    await db.delete(membersTable);
  }

  static Future<void> _insertSingleGroup(
    DatabaseExecutor db,
    TrainRecord record,
  ) async {
    await _insertPayload(db, _buildGroupPayload([record]));
  }

  static Future<void> _insertGroup(
    DatabaseExecutor db,
    List<TrainRecord> members, {
    String? preserveGroupId,
  }) async {
    if (members.isEmpty) return;
    await _insertPayload(
      db,
      _buildGroupPayload(members, groupId: preserveGroupId),
    );
  }

  static Future<void> _insertPayload(
    DatabaseExecutor db,
    Map<String, dynamic> group,
  ) async {
    final batch = db.batch();
    _addGroupToBatch(batch, group);
    await batch.commit(noResult: true);
  }

  static Iterable<List<T>> chunks<T>(List<T> values, [int size = 900]) sync* {
    for (var start = 0; start < values.length; start += size) {
      final end = (start + size < values.length) ? start + size : values.length;
      yield values.sublist(start, end);
    }
  }

  // ---------------------------------------------------------------------
  // Paged reads
  // ---------------------------------------------------------------------

  /// Keyset-paged merged display items, newest group first. Pass [cursor]
  /// from the previous page's [DisplayPageResult.nextCursor] to fetch the
  /// next page; pass null for the first page. This is stable against new
  /// records arriving at the top of the ordering (they land above the
  /// cursor), unlike offset/limit which would shift and re-return rows.
  static Future<DisplayPageResult> fetchPage(
    DatabaseExecutor db, {
    required String recordsTable,
    required int limit,
    PageCursor? cursor,
    bool hideUngroupable = false,
  }) async {
    final where = <String>[];
    final args = <dynamic>[];
    if (hideUngroupable) where.add('g.isUngroupable = 0');
    if (cursor != null) {
      where.add(
        '(g.latestReceivedTimestamp < ? OR '
        '(g.latestReceivedTimestamp = ? AND g.groupId > ?))',
      );
      args.addAll([cursor.timestamp, cursor.timestamp, cursor.id]);
    }
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = await db.rawQuery(
      '''
      SELECT
        g.groupId AS merge_group_id,
        g.memberCount AS grp_cnt,
        g.summaryJson AS summary_json,
        g.latestReceivedTimestamp,
        r.*
      FROM $groupsTable g
      INNER JOIN $recordsTable r ON r.uniqueId = g.representativeUniqueId
      $whereSql
      ORDER BY g.latestReceivedTimestamp DESC, g.groupId ASC
      LIMIT ?
      ''',
      [...args, limit],
    );
    final items = await _rowsToItems(db, rows);
    final next = rows.length < limit
        ? null
        : PageCursor(
            (rows.last['latestReceivedTimestamp'] as num).toInt(),
            rows.last['merge_group_id'].toString(),
          );
    return DisplayPageResult(items, next);
  }

  static Future<List<Object>> fetchSearchPage(
    DatabaseExecutor db, {
    required String recordsTable,
    required String searchWhereSql,
    required List<dynamic> searchWhereArgs,
    required String searchScoreSql,
    required List<dynamic> searchScoreArgs,
    required int limit,
    required int offset,
    bool hideUngroupable = false,
  }) async {
    final groupFilter = hideUngroupable ? 'AND g.isUngroupable = 0' : '';
    final rows = await db.rawQuery(
      '''
      WITH matched AS (
        SELECT
          r.uniqueId,
          $searchScoreSql AS match_score
        FROM $recordsTable r
        WHERE r.isTimeOnly = 0 AND ($searchWhereSql)
      ),
      hit_groups AS (
        SELECT
          gm.groupId,
          MAX(m.match_score) AS best_score
        FROM $membersTable gm
        INNER JOIN matched m ON m.uniqueId = gm.uniqueId
        GROUP BY gm.groupId
      )
      SELECT
        g.groupId AS merge_group_id,
        g.memberCount AS grp_cnt,
        g.summaryJson AS summary_json,
        r.*,
        h.best_score
      FROM hit_groups h
      INNER JOIN $groupsTable g ON g.groupId = h.groupId
      INNER JOIN $recordsTable r ON r.uniqueId = g.representativeUniqueId
      WHERE 1=1 $groupFilter
      ORDER BY h.best_score DESC, g.latestReceivedTimestamp DESC, g.groupId ASC
      LIMIT ? OFFSET ?
      ''',
      [...searchScoreArgs, ...searchWhereArgs, limit, offset],
    );
    return _rowsToItems(db, rows);
  }

  static Future<int> countSearchGroups(
    DatabaseExecutor db, {
    required String recordsTable,
    required String searchWhereSql,
    required List<dynamic> searchWhereArgs,
    bool hideUngroupable = false,
  }) async {
    final groupJoin = hideUngroupable
        ? 'INNER JOIN $groupsTable g ON g.groupId = gm.groupId AND g.isUngroupable = 0'
        : '';
    final result = await db.rawQuery('''
      WITH matched AS (
        SELECT r.uniqueId
        FROM $recordsTable r
        WHERE r.isTimeOnly = 0 AND ($searchWhereSql)
      )
      SELECT COUNT(DISTINCT gm.groupId) AS cnt
      FROM $membersTable gm
      $groupJoin
      INNER JOIN matched m ON m.uniqueId = gm.uniqueId
      ''', searchWhereArgs);
    return (result.first['cnt'] as num?)?.toInt() ?? 0;
  }

  /// Returns the display item (single record or merged group) that contains
  /// [uniqueId], or null when the record is not in the cache.
  static Future<Object?> itemContaining(
    DatabaseExecutor db, {
    required String recordsTable,
    required String uniqueId,
  }) async {
    final rows = await db.rawQuery(
      '''
      SELECT
        g.groupId AS merge_group_id,
        g.memberCount AS grp_cnt,
        g.summaryJson AS summary_json,
        r.*
      FROM $membersTable m
      INNER JOIN $groupsTable g ON g.groupId = m.groupId
      INNER JOIN $recordsTable r ON r.uniqueId = g.representativeUniqueId
      WHERE m.uniqueId = ?
      LIMIT 1
      ''',
      [uniqueId],
    );
    final items = await _rowsToItems(db, rows);
    return items.isEmpty ? null : items.first;
  }

  static Future<List<Object>> _rowsToItems(
    DatabaseExecutor db,
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return [];

    final groupIds = rows
        .map((r) => r['merge_group_id']?.toString())
        .whereType<String>()
        .toList();
    final placeholders = List.filled(groupIds.length, '?').join(',');
    final memberRows = await db.rawQuery('''
      SELECT groupId, GROUP_CONCAT(uniqueId, '$_idSep') AS member_ids
      FROM $membersTable
      WHERE groupId IN ($placeholders)
      GROUP BY groupId
      ''', groupIds);
    final membersByGroup = {
      for (final row in memberRows)
        row['groupId']?.toString(): row['member_ids']?.toString(),
    };

    final items = <Object>[];
    for (final row in rows) {
      final record = TrainRecord.fromDatabaseJson(row);
      final grpCnt = (row['grp_cnt'] as num?)?.toInt() ?? 1;
      final groupId = row['merge_group_id']?.toString() ?? record.uniqueId;
      final memberIds = _parseMemberIds(membersByGroup[groupId]);

      if (grpCnt >= 2) {
        TrainRecord summary = record;
        final summaryJson = row['summary_json']?.toString();
        if (summaryJson != null && summaryJson.isNotEmpty) {
          try {
            summary = TrainRecord.fromDatabaseJson(
              jsonDecode(summaryJson) as Map<String, dynamic>,
            );
          } catch (_) {}
        }
        items.add(
          MergedTrainRecord(
            groupKey: groupId,
            latestRecord: record,
            summaryRecord: summary,
            memberUniqueIds: memberIds.isNotEmpty
                ? memberIds
                : [record.uniqueId],
          ),
        );
      } else {
        items.add(record);
      }
    }
    return items;
  }

  static List<String> _parseMemberIds(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    return raw.split(_idSep).where((id) => id.isNotEmpty).toList();
  }
}

class _MutableGroup {
  final List<TrainRecord> members = [];
  _MutableGroup? redirect;
  int latestTs = 0;

  _MutableGroup(TrainRecord first) {
    add(first);
  }

  void add(TrainRecord record) {
    members.add(record);
    final ts = record.receivedTimestamp.millisecondsSinceEpoch;
    if (ts > latestTs) latestTs = ts;
  }
}

/// Groups [records] into merge-group payload entries using the fixed
/// session-window rule (train OR loco key, 1h window on receivedTimestamp).
///
/// [records] may be unsorted; this sorts ascending by receivedTimestamp
/// internally. Pure function — safe to call from an isolate. Shared by the
/// full rebuild path ([buildDisplayGroupsPayload]) and the JSON import path
/// ([prepareImportPayload]) so the two never diverge in grouping semantics.
List<Map<String, dynamic>> groupRecordsIntoPayload(List<TrainRecord> records) {
  final windowMs = DisplayGroupCache.mergeWindow.inMilliseconds;
  final sorted = List<TrainRecord>.from(records)
    ..sort((a, b) {
      final time = a.receivedTimestamp.compareTo(b.receivedTimestamp);
      return time != 0 ? time : a.uniqueId.compareTo(b.uniqueId);
    });

  final groups = <_MutableGroup>[];
  final activeByTrain = <String, _MutableGroup>{};
  final activeByLoco = <String, _MutableGroup>{};
  final lastTrainTimestamp = <String, int>{};
  final lastLocoTimestamp = <String, int>{};

  _MutableGroup resolve(_MutableGroup group) {
    var current = group;
    while (current.redirect != null) {
      current = current.redirect!;
    }
    return current;
  }

  for (final record in sorted) {
    final ts = record.receivedTimestamp.millisecondsSinceEpoch;
    final trainKey = record.trainKey;
    final locoKey = record.locoKey;

    _MutableGroup? pick(_MutableGroup? group, int? lastTimestamp) {
      if (group == null || lastTimestamp == null) return null;
      if (ts - lastTimestamp > windowMs) return null;
      final resolved = resolve(group);
      return resolved;
    }

    final byTrain = trainKey != null
        ? pick(activeByTrain[trainKey], lastTrainTimestamp[trainKey])
        : null;
    final byLoco = locoKey != null
        ? pick(activeByLoco[locoKey], lastLocoTimestamp[locoKey])
        : null;

    _MutableGroup target;
    if (byTrain == null && byLoco == null) {
      target = _MutableGroup(record);
      groups.add(target);
    } else {
      target = byTrain ?? byLoco!;
      if (byTrain != null && byLoco != null && !identical(byTrain, byLoco)) {
        // Union: fold the loco-keyed group into the train-keyed one.
        target.members.addAll(byLoco.members);
        if (byLoco.latestTs > target.latestTs) {
          target.latestTs = byLoco.latestTs;
        }
        byLoco.members.clear();
        byLoco.redirect = target;
      }
      target.add(record);
    }

    if (trainKey != null) {
      activeByTrain[trainKey] = target;
      lastTrainTimestamp[trainKey] = ts;
    }
    if (locoKey != null) {
      activeByLoco[locoKey] = target;
      lastLocoTimestamp[locoKey] = ts;
    }
  }

  final payload = <Map<String, dynamic>>[];

  for (final group in groups) {
    if (group.redirect != null || group.members.isEmpty) continue;
    payload.add(_buildGroupPayload(group.members));
  }
  return payload;
}

Map<String, dynamic> _buildGroupPayload(
  List<TrainRecord> members, {
  String? groupId,
}) {
  final sorted = List<TrainRecord>.from(members)
    ..sort((a, b) {
      final time = b.receivedTimestamp.compareTo(a.receivedTimestamp);
      return time != 0 ? time : b.uniqueId.compareTo(a.uniqueId);
    });
  final latest = sorted.first;
  final resolvedGroupId = groupId ?? sorted.last.uniqueId;
  final isUngroupable =
      sorted.length == 1 &&
      sorted.first.trainKey == null &&
      sorted.first.locoKey == null;
  return {
    'groupId': resolvedGroupId,
    'latestReceivedTimestamp': latest.receivedTimestamp.millisecondsSinceEpoch,
    'memberCount': sorted.length,
    'representativeUniqueId': latest.uniqueId,
    'summaryJson': sorted.length == 1
        ? ''
        : jsonEncode(MergeService.buildSummaryRecord(sorted).toTransferJson()),
    'isUngroupable': isUngroupable ? 1 : 0,
    'memberIds': sorted.map((record) => record.uniqueId).toList(),
  };
}

/// Top-level entry for [compute] used by the full rebuild: builds the group
/// payload from raw train_records row maps off the UI thread.
List<Map<String, dynamic>> buildDisplayGroupsPayload(
  List<Map<String, dynamic>> rows,
) {
  return groupRecordsIntoPayload(
    rows.map(TrainRecord.fromDatabaseJson).toList(),
  );
}

/// Top-level entry for [compute] used by the JSON import: turns raw JSON
/// record maps into insert-ready train_records rows plus the merge-group
/// payload, in a single off-UI-thread pass. Returns a map with:
/// - `rows`: `List<Map<String, dynamic>>` ready for train_records INSERT
///   (14 data fields + searchText + isTimeOnly + trainKey + locoKey).
/// - `groups`: `List<Map<String, dynamic>>` merge payload for
///   [DisplayGroupCache.applyPayload] (time-only records are stored but not
///   grouped, matching [DisplayGroupCache.rebuild]'s `WHERE isTimeOnly = 0`).
Map<String, dynamic> prepareImportPayload(
  List<Map<String, dynamic>> rawRecords,
) {
  final rows = <Map<String, dynamic>>[];
  final groupable = <TrainRecord>[];
  for (final raw in rawRecords) {
    final rec = TrainRecord.fromJson(raw);
    rows.add(rec.toDatabaseJson()..addAll(rec.derivedColumns()));
    if (!rec.isTimeOnly) groupable.add(rec);
  }
  return {'rows': rows, 'groups': groupRecordsIntoPayload(groupable)};
}
