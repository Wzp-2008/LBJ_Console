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
/// number are grouped together (union semantics) using session windows — a
/// record joins a group when it arrives within 1 hour of the group's latest
/// member, so a continuous transmission stream stays in one group no matter
/// how long it lasts; a gap larger than 1 hour starts a new group.
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
      CREATE INDEX IF NOT EXISTS idx_mdg_latest
      ON $groupsTable(latestReceivedTimestamp DESC)
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
    final row =
        await db.rawQuery('SELECT 1 FROM $groupsTable LIMIT 1');
    return row.isEmpty;
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
    final rows = await db.query(
      recordsTable,
      where: 'isTimeOnly = 0',
    );
    final plainRows =
        rows.map((r) => Map<String, dynamic>.from(r)).toList();

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
    batch.insert(
      groupsTable,
      {
        'groupId': groupId,
        'latestReceivedTimestamp': group['latestReceivedTimestamp'],
        'memberCount': group['memberCount'],
        'representativeUniqueId': group['representativeUniqueId'],
        'summaryJson': group['summaryJson'],
        'isUngroupable': group['isUngroupable'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    for (final id in group['memberIds'] as List) {
      batch.insert(
        membersTable,
        {'uniqueId': id, 'groupId': groupId},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  // ---------------------------------------------------------------------
  // Incremental updates
  // ---------------------------------------------------------------------

  /// Incrementally folds a newly inserted record into the cache.
  static Future<void> applyNewRecord(
    Database db, {
    required String recordsTable,
    required TrainRecord record,
  }) async {
    if (record.isTimeOnly) return;

    final ts = record.receivedTimestamp.millisecondsSinceEpoch;
    final windowMs = mergeWindow.inMilliseconds;
    final trainKey = record.trainKey;
    final locoKey = record.locoKey;

    await db.transaction((txn) async {
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
        final rows = await txn.rawQuery(
          '''
          SELECT DISTINCT g.groupId, g.latestReceivedTimestamp
          FROM $recordsTable r
          INNER JOIN $membersTable m ON m.uniqueId = r.uniqueId
          INNER JOIN $groupsTable g ON g.groupId = m.groupId
          WHERE (${keyClauses.join(' OR ')})
            AND g.latestReceivedTimestamp >= ?
          ''',
          [...keyArgs, ts - windowMs],
        );
        candidateIds = rows
            .where((row) {
              final latest =
                  (row['latestReceivedTimestamp'] as num).toInt();
              // The record must sit inside the window of the group too
              // (guards against late / out-of-order arrivals).
              return ts >= latest - windowMs;
            })
            .map((row) => row['groupId'].toString())
            .toList();
      }

      if (candidateIds.isEmpty) {
        await _insertSingleGroup(txn, record);
        return;
      }

      // Preserve the surviving groupId so the card identity (groupKey) stays
      // stable when an out-of-order (older) record folds into the group. The
      // lexicographically smallest candidate groupId equals the oldest
      // member's uniqueId, which is what a full rebuild would also pick — so
      // incremental and rebuild paths agree in the common (in-order) case,
      // and the incremental path is additionally stable on late arrivals.
      final survivor = candidateIds.reduce(
        (a, b) => a.compareTo(b) < 0 ? a : b,
      );

      final placeholders = List.filled(candidateIds.length, '?').join(',');
      final memberRows = await txn.rawQuery(
        '''
        SELECT r.* FROM $membersTable m
        INNER JOIN $recordsTable r ON r.uniqueId = m.uniqueId
        WHERE m.groupId IN ($placeholders)
        ''',
        candidateIds,
      );
      final members = <String, TrainRecord>{
        for (final row in memberRows)
          row['uniqueId'].toString(): TrainRecord.fromDatabaseJson(row),
        record.uniqueId: record,
      };

      await txn.delete(
        groupsTable,
        where: 'groupId IN ($placeholders)',
        whereArgs: candidateIds,
      );
      await txn.delete(
        membersTable,
        where: 'groupId IN ($placeholders)',
        whereArgs: candidateIds,
      );

      await _insertGroup(
        txn,
        members.values.toList(),
        preserveGroupId: survivor,
      );
    });
  }

  /// Incrementally removes deleted records from the cache; affected groups
  /// are recomputed from their remaining members.
  static Future<void> removeRecords(
    Database db, {
    required String recordsTable,
    required List<String> uniqueIds,
  }) async {
    if (uniqueIds.isEmpty) return;

    await db.transaction((txn) async {
      final placeholders = List.filled(uniqueIds.length, '?').join(',');
      final groupRows = await txn.rawQuery(
        'SELECT DISTINCT groupId FROM $membersTable WHERE uniqueId IN ($placeholders)',
        uniqueIds,
      );
      if (groupRows.isEmpty) return;
      final groupIds =
          groupRows.map((row) => row['groupId'].toString()).toList();

      await txn.delete(
        membersTable,
        where: 'uniqueId IN ($placeholders)',
        whereArgs: uniqueIds,
      );

      final groupPlaceholders = List.filled(groupIds.length, '?').join(',');
      final memberRows = await txn.rawQuery(
        '''
        SELECT m.groupId AS member_group_id, r.* FROM $membersTable m
        INNER JOIN $recordsTable r ON r.uniqueId = m.uniqueId
        WHERE m.groupId IN ($groupPlaceholders)
        ''',
        groupIds,
      );
      final membersByGroup = <String, List<TrainRecord>>{};
      for (final row in memberRows) {
        membersByGroup
            .putIfAbsent(row['member_group_id'].toString(), () => [])
            .add(TrainRecord.fromDatabaseJson(row));
      }

      await txn.delete(
        groupsTable,
        where: 'groupId IN ($groupPlaceholders)',
        whereArgs: groupIds,
      );

      for (final entry in membersByGroup.entries) {
        if (entry.value.isEmpty) continue;
        // Preserve the existing groupId so a delete never changes a
        // surviving card's identity.
        await _insertGroup(
          txn,
          entry.value,
          preserveGroupId: entry.key,
        );
      }
    });
  }

  static Future<void> clear(DatabaseExecutor db) async {
    await db.delete(groupsTable);
    await db.delete(membersTable);
  }

  static Future<void> _insertSingleGroup(
    DatabaseExecutor db,
    TrainRecord record,
  ) async {
    await db.insert(
      groupsTable,
      {
        'groupId': record.uniqueId,
        'latestReceivedTimestamp':
            record.receivedTimestamp.millisecondsSinceEpoch,
        'memberCount': 1,
        'representativeUniqueId': record.uniqueId,
        'summaryJson': '',
        'isUngroupable':
            (record.trainKey == null && record.locoKey == null) ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      membersTable,
      {'uniqueId': record.uniqueId, 'groupId': record.uniqueId},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> _insertGroup(
    DatabaseExecutor db,
    List<TrainRecord> members, {
    String? preserveGroupId,
  }) async {
    if (members.isEmpty) return;
    if (members.length == 1) {
      await _insertSingleGroup(db, members.first);
      return;
    }
    final sorted = List<TrainRecord>.from(members)
      ..sort((a, b) => b.receivedTimestamp.compareTo(a.receivedTimestamp));
    final latest = sorted.first;
    // Preserve an existing groupId when given (stable identity across folds
    // and shrinks); otherwise derive from the oldest member (full rebuild),
    // which keeps it stable as the group grows and collision-free against
    // singles.
    final groupId = preserveGroupId ?? sorted.last.uniqueId;
    final summary = MergeService.buildSummaryRecord(sorted);
    await db.insert(
      groupsTable,
      {
        'groupId': groupId,
        'latestReceivedTimestamp':
            latest.receivedTimestamp.millisecondsSinceEpoch,
        'memberCount': sorted.length,
        'representativeUniqueId': latest.uniqueId,
        'summaryJson': jsonEncode(summary.toTransferJson()),
        'isUngroupable': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    for (final member in sorted) {
      await db.insert(
        membersTable,
        {'uniqueId': member.uniqueId, 'groupId': groupId},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
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
    final whereSql =
        where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
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
    final result = await db.rawQuery(
      '''
      WITH matched AS (
        SELECT r.uniqueId
        FROM $recordsTable r
        WHERE r.isTimeOnly = 0 AND ($searchWhereSql)
      )
      SELECT COUNT(DISTINCT gm.groupId) AS cnt
      FROM $membersTable gm
      $groupJoin
      INNER JOIN matched m ON m.uniqueId = gm.uniqueId
      ''',
      searchWhereArgs,
    );
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
    final memberRows = await db.rawQuery(
      '''
      SELECT groupId, GROUP_CONCAT(uniqueId, '$_idSep') AS member_ids
      FROM $membersTable
      WHERE groupId IN ($placeholders)
      GROUP BY groupId
      ''',
      groupIds,
    );
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
            memberUniqueIds:
                memberIds.isNotEmpty ? memberIds : [record.uniqueId],
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
List<Map<String, dynamic>> groupRecordsIntoPayload(
  List<TrainRecord> records,
) {
  final windowMs = DisplayGroupCache.mergeWindow.inMilliseconds;
  final sorted = List<TrainRecord>.from(records)
    ..sort((a, b) => a.receivedTimestamp.compareTo(b.receivedTimestamp));

  final groups = <_MutableGroup>[];
  final activeByTrain = <String, _MutableGroup>{};
  final activeByLoco = <String, _MutableGroup>{};

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

    _MutableGroup? pick(_MutableGroup? group) {
      if (group == null) return null;
      final resolved = resolve(group);
      if (ts - resolved.latestTs > windowMs) return null;
      return resolved;
    }

    final byTrain = trainKey != null ? pick(activeByTrain[trainKey]) : null;
    final byLoco = locoKey != null ? pick(activeByLoco[locoKey]) : null;

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

    if (trainKey != null) activeByTrain[trainKey] = target;
    if (locoKey != null) activeByLoco[locoKey] = target;
  }

  final payload = <Map<String, dynamic>>[];

  Map<String, dynamic> singlePayload(TrainRecord record) {
    return {
      'groupId': record.uniqueId,
      'latestReceivedTimestamp':
          record.receivedTimestamp.millisecondsSinceEpoch,
      'memberCount': 1,
      'representativeUniqueId': record.uniqueId,
      'summaryJson': '',
      'isUngroupable':
          (record.trainKey == null && record.locoKey == null) ? 1 : 0,
      'memberIds': [record.uniqueId],
    };
  }

  for (final group in groups) {
    if (group.redirect != null || group.members.isEmpty) continue;
    if (group.members.length == 1) {
      payload.add(singlePayload(group.members.first));
      continue;
    }
    final sortedMembers = List<TrainRecord>.from(group.members)
      ..sort((a, b) => b.receivedTimestamp.compareTo(a.receivedTimestamp));
    final latest = sortedMembers.first;
    final oldest = sortedMembers.last;
    final summary = MergeService.buildSummaryRecord(sortedMembers);
    payload.add({
      'groupId': oldest.uniqueId,
      'latestReceivedTimestamp':
          latest.receivedTimestamp.millisecondsSinceEpoch,
      'memberCount': sortedMembers.length,
      'representativeUniqueId': latest.uniqueId,
      'summaryJson': jsonEncode(summary.toTransferJson()),
      'isUngroupable': 0,
      'memberIds': sortedMembers.map((r) => r.uniqueId).toList(),
    });
  }
  return payload;
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
Map<String, dynamic> prepareImportPayload(List<Map<String, dynamic>> rawRecords) {
  final rows = <Map<String, dynamic>>[];
  final groupable = <TrainRecord>[];
  for (final raw in rawRecords) {
    final rec = TrainRecord.fromJson(raw);
    rows.add(rec.toDatabaseJson()..addAll(rec.derivedColumns()));
    if (!rec.isTimeOnly) groupable.add(rec);
  }
  return {'rows': rows, 'groups': groupRecordsIntoPayload(groupable)};
}
