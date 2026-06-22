import 'package:lbjconsole/models/train_record.dart';
import 'package:lbjconsole/services/database_service.dart';
import 'package:lbjconsole/services/display_group_cache.dart';

// Re-export the keyset pagination types so UI code only needs to import
// RecordsFeed.
export 'package:lbjconsole/services/display_group_cache.dart'
    show PageCursor, DisplayPageResult;

/// Unified paged query API for the records list.
///
/// Chooses the SQL path from the current settings so the UI never branches:
/// - merge enabled  -> pages over the pre-computed merge group cache
/// - merge disabled -> pages over raw records
/// Time-only records are always hidden (filtered at write time).
///
/// Non-search pagination is **keyset** (cursor) based: each page returns
/// items strictly after the previous page's cursor in a stable total order,
/// so it is immune to new records arriving at the top of the list (they land
/// above the cursor). This fixes the old offset/limit "list never changes /
/// shows no data" bug on a live stream.
///
/// Search pagination stays offset-based: the corpus is static for the
/// duration of a search session (live [HistoryScreen.addNewRecord] calls
/// early-return while a search is active), so offset + a total-order
/// tiebreaker + the UI's dedup safety net is correct and far simpler than a
/// score-based cursor.
class RecordsFeed {
  RecordsFeed._();

  static Future<({bool mergeEnabled, bool hideUngroupable})>
      _displaySettings() async {
    final settings = await DatabaseService.instance.getAllSettings() ?? {};
    return (
      mergeEnabled: (settings['mergeRecordsEnabled'] ?? 0) == 1,
      hideUngroupable: (settings['hideUngroupableRecords'] ?? 0) == 1,
    );
  }

  /// One page of display items (TrainRecord or MergedTrainRecord), newest
  /// first. Pass [cursor] from a previous result's [DisplayPageResult.nextCursor]
  /// to load the next page; pass null for the first page.
  static Future<DisplayPageResult> fetchPage({
    required int limit,
    PageCursor? cursor,
  }) async {
    final settings = await _displaySettings();
    if (settings.mergeEnabled) {
      return DatabaseService.instance.fetchDisplayPage(
        limit: limit,
        cursor: cursor,
        hideUngroupable: settings.hideUngroupable,
      );
    }
    return DatabaseService.instance.fetchPlainPage(
      limit: limit,
      cursor: cursor,
      hideUngroupable: settings.hideUngroupable,
    );
  }

  /// One page of search results; merged when merge is enabled.
  static Future<List<Object>> fetchSearchPage({
    required String query,
    required int limit,
    required int offset,
  }) async {
    final settings = await _displaySettings();
    if (settings.mergeEnabled) {
      return DatabaseService.instance.searchDisplayPage(
        query: query,
        limit: limit,
        offset: offset,
        hideUngroupable: settings.hideUngroupable,
      );
    }
    final records = await DatabaseService.instance.searchRecordsFuzzy(
      query: query,
      limit: limit,
      offset: offset,
    );
    return records.cast<Object>();
  }

  /// Total search hits: matching groups when merged, records otherwise.
  static Future<int> countSearch(String query) async {
    final settings = await _displaySettings();
    if (settings.mergeEnabled) {
      return DatabaseService.instance.countSearchDisplayGroups(
        query,
        hideUngroupable: settings.hideUngroupable,
      );
    }
    return DatabaseService.instance.countSearchResults(query);
  }

  /// The up-to-date display item containing [record], or null when the
  /// record should not be displayed (time-only, or hidden by settings).
  static Future<Object?> itemContaining(TrainRecord record) async {
    if (record.isTimeOnly) return null;
    final settings = await _displaySettings();
    if (!settings.mergeEnabled) {
      return record;
    }
    final item =
        await DatabaseService.instance.displayItemContaining(record.uniqueId);
    if (item == null) return null;
    if (settings.hideUngroupable &&
        item is TrainRecord &&
        item.trainKey == null &&
        item.locoKey == null) {
      return null;
    }
    return item;
  }
}
