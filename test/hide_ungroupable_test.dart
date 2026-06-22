import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const int _minute = 60 * 1000;
const int _base = 1700000000000;

String _identity(Object item) =>
    item is MergedTrainRecord ? 'm:${item.groupKey}' : 't:${(item as TrainRecord).uniqueId}';

void main() {
  group('hideUngroupable (synthetic)', () {
    setUp(() async {
      await initTestDb();
    });
    tearDown(() async {
      await disposeTestDatabase();
    });

    test('merge ON: ungroupable group is hidden when the option is on', () async {
      await DatabaseService.instance.updateSettings(
          {'mergeRecordsEnabled': 1, 'hideUngroupableRecords': 0});
      // Ungroupable: route only (non-time-only) but no train/loco key.
      await DatabaseService.instance.insertRecord(
          mkRecord(uniqueId: 'u1', receivedMs: _base, route: 'R1', direction: 1));
      // Groupable: has a train key.
      await DatabaseService.instance.insertRecord(
          mkRecord(uniqueId: 'g1', receivedMs: _base + _minute, train: 'T1', direction: 1));

      final shown = await RecordsFeed.fetchPage(limit: 100, cursor: null);
      expect(shown.items.map(_identity).toSet(), {'t:u1', 't:g1'});

      await DatabaseService.instance.updateSettings(
          {'mergeRecordsEnabled': 1, 'hideUngroupableRecords': 1});
      final hidden = await RecordsFeed.fetchPage(limit: 100, cursor: null);
      expect(hidden.items.map(_identity).toSet(), {'t:g1'},
          reason: 'ungroupable u1 must be hidden when hideUngroupable is on');
    });

    test('merge OFF: records with no train/loco are hidden when the option is on',
        () async {
      await DatabaseService.instance.updateSettings(
          {'mergeRecordsEnabled': 0, 'hideUngroupableRecords': 0});
      await DatabaseService.instance.insertRecord(
          mkRecord(uniqueId: 'u1', receivedMs: _base, route: 'R1', direction: 1));
      await DatabaseService.instance.insertRecord(
          mkRecord(uniqueId: 'g1', receivedMs: _base + _minute, train: 'T1', direction: 1));

      final shown = await RecordsFeed.fetchPage(limit: 100, cursor: null);
      expect(shown.items.length, 2);

      await DatabaseService.instance.updateSettings(
          {'mergeRecordsEnabled': 0, 'hideUngroupableRecords': 1});
      final hidden = await RecordsFeed.fetchPage(limit: 100, cursor: null);
      expect(hidden.items.length, 1,
          reason: 'the no-train/no-loco record must be hidden in merge-off too');
      expect((hidden.items.single as TrainRecord).uniqueId, 'g1');
    });

    test('merge OFF: a record with only a loco key is NOT hidden', () async {
      await DatabaseService.instance.updateSettings(
          {'mergeRecordsEnabled': 0, 'hideUngroupableRecords': 1});
      await DatabaseService.instance.insertRecord(
          mkRecord(uniqueId: 'l1', receivedMs: _base, loco: '41010559', direction: 1));
      final result = await RecordsFeed.fetchPage(limit: 100, cursor: null);
      expect(result.items.length, 1,
          reason: 'a loco-keyed record is groupable and must stay visible');
    });

    test('itemContaining drops a live ungroupable record when the option is on',
        () async {
      await DatabaseService.instance.updateSettings(
          {'mergeRecordsEnabled': 1, 'hideUngroupableRecords': 1});
      final ungroupable =
          mkRecord(uniqueId: 'u1', receivedMs: _base, route: 'R1', direction: 1);
      await DatabaseService.instance.insertRecord(ungroupable);
      // A live insert of an ungroupable record must not surface it.
      expect(await RecordsFeed.itemContaining(ungroupable), isNull);
    });

    test('itemContaining still surfaces a groupable record when the option is on',
        () async {
      await DatabaseService.instance.updateSettings(
          {'mergeRecordsEnabled': 1, 'hideUngroupableRecords': 1});
      final rec =
          mkRecord(uniqueId: 'g1', receivedMs: _base, train: 'T1', direction: 1);
      await DatabaseService.instance.insertRecord(rec);
      expect(await RecordsFeed.itemContaining(rec), isNotNull);
    });

    test('search hides ungroupable hits when the option is on (merge ON)',
        () async {
      await DatabaseService.instance.updateSettings(
          {'mergeRecordsEnabled': 1, 'hideUngroupableRecords': 1});
      await DatabaseService.instance.insertRecord(mkRecord(
          uniqueId: 'u1', receivedMs: _base, route: '京九线', direction: 1));
      await DatabaseService.instance.insertRecord(mkRecord(
          uniqueId: 'g1',
          receivedMs: _base + _minute,
          train: 'T1',
          route: '京九线',
          direction: 1));

      final total = await RecordsFeed.countSearch('京九');
      final page = await RecordsFeed.fetchSearchPage(query: '京九', limit: 100, offset: 0);
      expect(page.length, total);
      expect(page.map(_identity).toSet(), isNot(contains('t:u1')),
          reason: 'ungroupable u1 must not appear in search results');
    });
  });

  group('hideUngroupable (real sample data)', () {
    setUpAll(() async {
      await initTestDb();
      await DatabaseService.instance.updateSettings({'mergeRecordsEnabled': 1});
      final ok = await DatabaseService.instance
          .importDataFromJson(sampleJsonPath());
      expect(ok, isTrue);
    });

    tearDownAll(() async {
      await disposeTestDatabase();
    });

    test('merge ON: walks exactly the non-ungroupable groups', () async {
      final allGroups = await DatabaseService.instance
          .countDisplayGroupsForTesting(hideUngroupable: false);
      final nonUngroupable = await DatabaseService.instance
          .countDisplayGroupsForTesting(hideUngroupable: true);
      expect(nonUngroupable, lessThan(allGroups),
          reason: 'the sample must contain ungroupable groups');

      await DatabaseService.instance.updateSettings(
          {'mergeRecordsEnabled': 1, 'hideUngroupableRecords': 1});
      var walked = 0;
      PageCursor? cursor;
      do {
        final r = await RecordsFeed.fetchPage(limit: 1000, cursor: cursor);
        walked += r.items.length;
        cursor = r.nextCursor;
      } while (cursor != null);
      expect(walked, nonUngroupable);
    });

    test('merge OFF: walks exactly the records with a train or loco key', () async {
      final allPlain = await DatabaseService.instance
          .expectedDisplayTotalForTesting(
              mergeEnabled: false, hideUngroupable: false);
      final filteredPlain = await DatabaseService.instance
          .expectedDisplayTotalForTesting(
              mergeEnabled: false, hideUngroupable: true);
      expect(filteredPlain, lessThan(allPlain),
          reason: 'the sample must contain no-train/no-loco records');

      await DatabaseService.instance.updateSettings(
          {'mergeRecordsEnabled': 0, 'hideUngroupableRecords': 1});
      var walked = 0;
      PageCursor? cursor;
      do {
        final r = await RecordsFeed.fetchPage(limit: 1000, cursor: cursor);
        walked += r.items.length;
        cursor = r.nextCursor;
      } while (cursor != null);
      expect(walked, filteredPlain);
    });
  });
}
