import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Keyset pagination correctness against the real sample data. The DB is
/// imported once in [setUpAll] and shared across tests (read-only except the
/// live-insert regression test, which is ordered last in its group).
void main() {
  setUpAll(() async {
    await initTestDb();
    final ok = await DatabaseService.instance
        .importDataFromJson(sampleJsonPath());
    expect(ok, isTrue);
  });

  tearDownAll(() async {
    await disposeTestDatabase();
  });

  /// Walks every page of the current feed until the cursor terminates,
  /// asserting no duplicate item identity and that the total equals the
  /// expected display total. Uses a large page size to keep the walk cheap.
  Future<({int walked, int expected})> walkAll({
    required bool mergeEnabled,
    int limit = 1000,
  }) async {
    await DatabaseService.instance.updateSettings({
      'mergeRecordsEnabled': mergeEnabled ? 1 : 0,
      'hideUngroupableRecords': 0,
    });
    final seen = <String>{};
    PageCursor? cursor;
    var walked = 0;
    while (true) {
      final result = await RecordsFeed.fetchPage(limit: limit, cursor: cursor);
      for (final item in result.items) {
        final id = _identity(item);
        expect(seen, isNot(contains(id)),
            reason: 'duplicate item across pages: $id');
        seen.add(id);
        walked++;
      }
      cursor = result.nextCursor;
      if (cursor == null) break;
    }
    final expected = await DatabaseService.instance
        .expectedDisplayTotalForTesting(mergeEnabled: mergeEnabled);
    return (walked: walked, expected: expected);
  }

  group('merged keyset pagination', () {
    test('visits every group exactly once, no skips, terminates', () async {
      final r = await walkAll(mergeEnabled: true);
      // ignore: avoid_print
      print('  merged: walked=${r.walked} expected=${r.expected}');
      expect(r.walked, r.expected,
          reason: 'walked item count must equal total group count');
    });

    test('first page returns newest items with a non-null next cursor',
        () async {
      await DatabaseService.instance
          .updateSettings({'mergeRecordsEnabled': 1});
      final result = await RecordsFeed.fetchPage(limit: 50, cursor: null);
      expect(result.items.length, 50);
      expect(result.nextCursor, isNotNull);
    });
  });

  group('plain (merge-off) keyset pagination', () {
    test('visits every record exactly once, no skips, terminates', () async {
      final r = await walkAll(mergeEnabled: false);
      // ignore: avoid_print
      print('  plain: walked=${r.walked} expected=${r.expected}');
      expect(r.walked, r.expected,
          reason: 'walked item count must equal displayable record count');
    });
  });

  group('hideUngroupable', () {
    test('count and walk agree when ungroupable groups are hidden', () async {
      await DatabaseService.instance.updateSettings({
        'mergeRecordsEnabled': 1,
        'hideUngroupableRecords': 1,
      });
      final seen = <String>{};
      PageCursor? cursor;
      var walked = 0;
      while (true) {
        final result = await RecordsFeed.fetchPage(limit: 1000, cursor: cursor);
        for (final item in result.items) {
          final id = _identity(item);
          expect(seen, isNot(contains(id)), reason: 'dup: $id');
          seen.add(id);
          walked++;
        }
        cursor = result.nextCursor;
        if (cursor == null) break;
      }
      final expected = await DatabaseService.instance
          .expectedDisplayTotalForTesting(
              mergeEnabled: true, hideUngroupable: true);
      expect(walked, expected);
    });
  });

  group('live insert does not perturb pagination', () {
    // Regression for the user's bug: new records arriving at the top must
    // never cause already-loaded pages to be re-returned (which, with the
    // old offset/limit + dedup, eventually yielded empty pages and a stuck
    // "no data" list).
    test('inserting mid-pagination keeps pages duplicate-free', () async {
      await DatabaseService.instance.updateSettings({
        'mergeRecordsEnabled': 1,
        'hideUngroupableRecords': 0,
      });

      // Load the first two pages (the user is now scrolled into the list).
      final first = await RecordsFeed.fetchPage(limit: 100, cursor: null);
      final second =
          await RecordsFeed.fetchPage(limit: 100, cursor: first.nextCursor);
      final seen = <String>{
        ...first.items.map(_identity),
        ...second.items.map(_identity),
      };
      expect(seen.length, 200, reason: 'first two pages must be unique');

      // While paginated, 50 brand-new records arrive at the top.
      final latestMs = _receivedMs(first.items.first) + 60000;
      for (var i = 0; i < 50; i++) {
        await DatabaseService.instance.insertRecord(mkRecord(
          uniqueId: 'live_insert_$i',
          receivedMs: latestMs + i * 1000,
          train: 'G${4000 + i}',
          direction: 1,
          lbjClass: 'K',
          loco: '13800${i.toString().padLeft(2, '0')}',
        ));
      }

      // Continue paging towards older items.
      var cursor = second.nextCursor;
      for (var page = 0; page < 5 && cursor != null; page++) {
        final result = await RecordsFeed.fetchPage(limit: 100, cursor: cursor);
        for (final item in result.items) {
          final id = _identity(item);
          expect(seen, isNot(contains(id)),
              reason: 'live insert caused a duplicate on page ${page + 3}: $id');
          seen.add(id);
        }
        cursor = result.nextCursor;
      }
    });
  });
}

String _identity(Object item) {
  if (item is MergedTrainRecord) return 'm:${item.groupKey}';
  if (item is TrainRecord) return 't:${item.uniqueId}';
  return 'x:${item.hashCode}';
}

int _receivedMs(Object item) {
  if (item is MergedTrainRecord) {
    return item.latestRecord.receivedTimestamp.millisecondsSinceEpoch;
  }
  return (item as TrainRecord).receivedTimestamp.millisecondsSinceEpoch;
}
