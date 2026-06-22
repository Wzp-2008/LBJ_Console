import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  setUp(() async {
    await initTestDb();
  });

  tearDown(() async {
    await disposeTestDatabase();
  });

  group('add', () {
    test('inserted record is persisted and counted', () async {
      await DatabaseService.instance.insertRecord(mkRecord(
        uniqueId: 'add1',
        receivedMs: 1700000000000,
        train: 'K1234',
        loco: '41010559',
        direction: 1,
        lbjClass: 'K',
      ));
      expect(await DatabaseService.instance.getRecordCount(), 1);

      final fetched = await DatabaseService.instance.getRecordsByUniqueIds(['add1']);
      expect(fetched.length, 1);
      expect(fetched.first.train, 'K1234');
    });

    test('cache is updated incrementally on insert', () async {
      await DatabaseService.instance
          .updateSettings({'mergeRecordsEnabled': 1});
      await DatabaseService.instance.insertRecord(mkRecord(
        uniqueId: 'add2',
        receivedMs: 1700000000000,
        train: 'K1234',
        loco: '41010559',
        direction: 1,
        lbjClass: 'K',
      ));
      final result = await RecordsFeed.fetchPage(limit: 10, cursor: null);
      expect(result.items.length, 1);
      expect(result.nextCursor, isNull);
    });
  });

  group('delete', () {
    test('single delete removes the record and its cache entry', () async {
      await DatabaseService.instance.insertRecord(mkRecord(
        uniqueId: 'd1',
        receivedMs: 1700000000000,
        train: 'K1234',
        loco: '41010559',
        direction: 1,
        lbjClass: 'K',
      ));
      await DatabaseService.instance
          .updateSettings({'mergeRecordsEnabled': 1});
      expect((await RecordsFeed.fetchPage(limit: 10, cursor: null)).items.length, 1);

      await DatabaseService.instance.deleteRecord('d1');
      expect(await DatabaseService.instance.getRecordCount(), 0);
      expect(
        (await RecordsFeed.fetchPage(limit: 10, cursor: null)).items,
        isEmpty,
      );
    });

    test('batch delete removes all listed records', () async {
      for (var i = 0; i < 5; i++) {
        await DatabaseService.instance.insertRecord(mkRecord(
          uniqueId: 'b$i',
          receivedMs: 1700000000000 + i * 60000,
          train: 'T$i',
          loco: 'L$i',
          direction: 1,
          lbjClass: 'K',
        ));
      }
      expect(await DatabaseService.instance.getRecordCount(), 5);

      await DatabaseService.instance.deleteRecords(['b0', 'b2', 'b4']);
      expect(await DatabaseService.instance.getRecordCount(), 2);
      final remaining = await DatabaseService.instance.getRecordsByUniqueIds(
        ['b0', 'b1', 'b2', 'b3', 'b4'],
      );
      expect(remaining.map((r) => r.uniqueId).toSet(), {'b1', 'b3'});
    });
  });

  group('search (merge off)', () {
    setUp(() async {
      await DatabaseService.instance
          .updateSettings({'mergeRecordsEnabled': 0});
      await DatabaseService.instance.insertRecord(mkRecord(
        uniqueId: 's1',
        receivedMs: 1700000000000,
        train: '1234',
        loco: '41010559',
        direction: 1,
        lbjClass: 'K',
        route: '京九线',
      ));
      await DatabaseService.instance.insertRecord(mkRecord(
        uniqueId: 's2',
        receivedMs: 1700000000000 + 60000,
        train: '5678',
        loco: '13800347',
        direction: 1,
        lbjClass: 'K',
        route: '沪昆线',
      ));
    });

    test('fuzzy search finds by train number', () async {
      final hits = await DatabaseService.instance
          .searchRecordsFuzzy(query: '1234', limit: 10, offset: 0);
      expect(hits.length, 1);
      expect(hits.first.uniqueId, 's1');
    });

    test('countSearch matches the page count for a fresh query', () async {
      final total = await RecordsFeed.countSearch('K');
      final page = await RecordsFeed.fetchSearchPage(
        query: 'K', limit: 10, offset: 0,
      );
      expect(page.length, total);
      expect(total, 2);
    });
  });

  group('search (merge on)', () {
    setUp(() async {
      await DatabaseService.instance
          .updateSettings({'mergeRecordsEnabled': 1});
      // Two records that merge into one group (same train, within 1h).
      await DatabaseService.instance.insertRecord(mkRecord(
        uniqueId: 'm1',
        receivedMs: 1700000000000,
        train: '9999',
        loco: '41010559',
        direction: 1,
        lbjClass: 'K',
      ));
      await DatabaseService.instance.insertRecord(mkRecord(
        uniqueId: 'm2',
        receivedMs: 1700000000000 + 60000,
        train: '9999',
        loco: '41010559',
        direction: 1,
        lbjClass: 'K',
      ));
    });

    test('merged search returns the group containing the hit', () async {
      final page = await RecordsFeed.fetchSearchPage(
        query: '9999', limit: 10, offset: 0,
      );
      expect(page.length, 1);
      final merged = page.single as MergedTrainRecord;
      expect(merged.recordCount, 2);
    });

    test('countSearch matches the page count', () async {
      final total = await RecordsFeed.countSearch('9999');
      expect(total, 1);
      final page = await RecordsFeed.fetchSearchPage(
        query: '9999', limit: 10, offset: 0,
      );
      expect(page.length, total);
    });
  });
}
