import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Performance budgets for the records data layer, measured against the real
/// sample file `LBJ_Console_output.json` (32 696 records).
///
/// The DB is imported once in [setUpAll] (and timed); all tests in this file
/// share that imported in-memory database, so they must be read-only except
/// the incremental-insert test which is ordered last.
void main() {
  int? importMs;

  setUpAll(() async {
    await initTestDb();
    // Exercise the merged path (the one the pagination bug affected).
    await DatabaseService.instance
        .updateSettings({'mergeRecordsEnabled': 1});
    final sw = Stopwatch()..start();
    final ok = await DatabaseService.instance
        .importDataFromJson(sampleJsonPath());
    importMs = sw.elapsedMilliseconds;
    expect(ok, isTrue, reason: 'import should succeed');
  });

  tearDownAll(() async {
    await disposeTestDatabase();
  });

  test('initial import (incl. cache + FTS rebuild) under 20s', () {
    // ignore: avoid_print
    print('  import took ${importMs}ms');
    expect(importMs!, lessThan(20000));
  });

  test('imported record count matches the JSON (32696)', () async {
    expect(await DatabaseService.instance.getRecordCount(), 32696);
  });

  test('merge cache was populated', () async {
    final groups = await DatabaseService.instance
        .countDisplayGroupsForTesting();
    expect(groups, greaterThan(0));
    // ignore: avoid_print
    print('  merge groups: $groups');
  });

  test('first page load under 4s', () async {
    final sw = Stopwatch()..start();
    final result = await RecordsFeed.fetchPage(limit: 100, cursor: null);
    sw.stop();
    // ignore: avoid_print
    print('  first page took ${sw.elapsedMilliseconds}ms');
    expect(sw.elapsedMilliseconds, lessThan(4000));
    expect(result.items.length, 100);
    expect(result.nextCursor, isNotNull,
        reason: 'with 32696 records there must be more pages');
  });

  test('mid-list page load under 4s', () async {
    // Walk two pages in to reach a mid-list cursor.
    final first = await RecordsFeed.fetchPage(limit: 100, cursor: null);
    final sw = Stopwatch()..start();
    final second = await RecordsFeed.fetchPage(
      limit: 100,
      cursor: first.nextCursor,
    );
    sw.stop();
    // ignore: avoid_print
    print('  mid-list page took ${sw.elapsedMilliseconds}ms');
    expect(sw.elapsedMilliseconds, lessThan(4000));
    expect(second.items.length, 100);
  });

  test('incremental insert+merge refresh under 1s', () async {
    // Find the latest group so the new record actually folds into it
    // (exercises applyNewRecord's merge path, not just a singleton insert).
    final first = await RecordsFeed.fetchPage(limit: 1, cursor: null);
    final latest = first.items.single;
    final baseMs = latest is MergedTrainRecord
        ? latest.latestRecord.receivedTimestamp.millisecondsSinceEpoch
        : (latest as TrainRecord).receivedTimestamp.millisecondsSinceEpoch;
    final train = latest is MergedTrainRecord
        ? latest.summaryRecord.train
        : (latest as TrainRecord).train;

    final newRecord = mkRecord(
      uniqueId: 'perf_insert_${baseMs + 60000}',
      receivedMs: baseMs + 60000, // 1 minute after the latest -> within window
      train: train.isEmpty ? '99999' : train,
      direction: 1,
      lbjClass: 'K',
      loco: '41010559',
    );

    final sw = Stopwatch()..start();
    await DatabaseService.instance.insertRecord(newRecord);
    sw.stop();
    // ignore: avoid_print
    print('  insert+merge took ${sw.elapsedMilliseconds}ms');
    expect(sw.elapsedMilliseconds, lessThan(1000));

    // The new record must be reachable as the display item it merged into.
    final item = await RecordsFeed.itemContaining(newRecord);
    expect(item, isNotNull);
  });
}
