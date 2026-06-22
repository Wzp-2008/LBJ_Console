import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const int _minute = 60 * 1000;
const int _base = 1700000000000; // 2023-11-14T22:13:20Z

void main() {
  setUp(() async {
    await initTestDb();
    await DatabaseService.instance
        .updateSettings({'mergeRecordsEnabled': 1, 'hideUngroupableRecords': 0});
  });

  tearDown(() async {
    await disposeTestDatabase();
  });

  /// Fetches every display item currently in the feed (merge on).
  Future<List<Object>> allItems() async {
    final result = await RecordsFeed.fetchPage(limit: 1000, cursor: null);
    return result.items;
  }

  test('same train within 1h -> one group; >1h -> separate groups', () async {
    await DatabaseService.instance.insertRecord(mkRecord(
      uniqueId: 'a',
      receivedMs: _base,
      train: 'T1',
      direction: 1,
    ));
    await DatabaseService.instance.insertRecord(mkRecord(
      uniqueId: 'b',
      receivedMs: _base + 30 * _minute, // 30min later, within window
      train: 'T1',
      direction: 1,
    ));
    await DatabaseService.instance.insertRecord(mkRecord(
      uniqueId: 'c',
      receivedMs: _base + 95 * _minute, // 65min after b -> new group
      train: 'T1',
      direction: 1,
    ));

    final items = await allItems();
    final merged =
        items.whereType<MergedTrainRecord>().toList();
    final singles = items.whereType<TrainRecord>().toList();
    expect(merged.length, 1, reason: 'a+b form one merged group');
    expect(merged.first.recordCount, 2);
    expect(singles.length, 1, reason: 'c is its own group (>1h gap)');
    expect(singles.first.uniqueId, 'c');
  });

  test('union: a record bridging train-key and loco-key groups merges them',
      () async {
    // recA: train TA + loco L1
    await DatabaseService.instance.insertRecord(mkRecord(
      uniqueId: 'A',
      receivedMs: _base,
      train: 'TA',
      loco: 'L1',
      direction: 1,
    ));
    // recB: loco L1 (matches A's loco) -> joins A's group
    await DatabaseService.instance.insertRecord(mkRecord(
      uniqueId: 'B',
      receivedMs: _base + 10 * _minute,
      train: 'TB',
      loco: 'L1',
      direction: 1,
    ));
    // recC: train TA (matches A's train) -> joins the same group
    await DatabaseService.instance.insertRecord(mkRecord(
      uniqueId: 'C',
      receivedMs: _base + 20 * _minute,
      train: 'TA',
      loco: 'L2',
      direction: 1,
    ));

    final items = await allItems();
    expect(items.length, 1, reason: 'all three bridge into one group');
    final merged = items.single as MergedTrainRecord;
    expect(merged.recordCount, 3);
    expect(merged.memberUniqueIds.toSet(), {'A', 'B', 'C'});
  });

  test('isUngroupable singleton is hidden when hideUngroupable is on', () async {
    await DatabaseService.instance.insertRecord(mkRecord(
      uniqueId: 'u',
      receivedMs: _base,
      route: 'R1', // route makes it non-time-only, but no train/loco key
      direction: 1,
    ));

    await DatabaseService.instance
        .updateSettings({'mergeRecordsEnabled': 1, 'hideUngroupableRecords': 0});
    final shown = await allItems();
    expect(shown.length, 1, reason: 'ungroupable shown when filter off');

    await DatabaseService.instance
        .updateSettings({'mergeRecordsEnabled': 1, 'hideUngroupableRecords': 1});
    final hidden = await allItems();
    expect(hidden, isEmpty, reason: 'ungroupable hidden when filter on');

    final total = await DatabaseService.instance
        .expectedDisplayTotalForTesting(
            mergeEnabled: true, hideUngroupable: true);
    expect(total, 0);
  });

  test('groupId stays stable when an older (out-of-order) record folds in',
      () async {
    // Insert two same-train records -> group forms with groupId = 'g1'
    // (the lexicographically smaller uniqueId, assigned at creation).
    await DatabaseService.instance.insertRecord(mkRecord(
      uniqueId: 'g1',
      receivedMs: _base,
      train: 'TG',
      direction: 1,
    ));
    await DatabaseService.instance.insertRecord(mkRecord(
      uniqueId: 'g2',
      receivedMs: _base + 10 * _minute,
      train: 'TG',
      direction: 1,
    ));

    final before =
        (await RecordsFeed.itemContaining(mkRecord(
      uniqueId: 'g1',
      receivedMs: _base,
      train: 'TG',
    ))) as MergedTrainRecord;
    expect(before.groupKey, 'g1');
    expect(before.recordCount, 2);

    // Now an OLDER record arrives late (out-of-order) and merges in.
    await DatabaseService.instance.insertRecord(mkRecord(
      uniqueId: 'g0',
      receivedMs: _base - 5 * _minute, // older than g1, within 1h
      train: 'TG',
      direction: 1,
    ));

    final after =
        (await RecordsFeed.itemContaining(mkRecord(
      uniqueId: 'g0',
      receivedMs: _base - 5 * _minute,
      train: 'TG',
    ))) as MergedTrainRecord;
    // The card identity must NOT have changed to 'g0' (the new oldest).
    expect(after.groupKey, 'g1',
        reason: 'groupId must stay stable across out-of-order arrivals');
    expect(after.recordCount, 3);
    expect(after.memberUniqueIds.toSet(), {'g0', 'g1', 'g2'});
  });

  test('merged summary surfaces complete data when the newest member is broken',
      () async {
    // Two records merge via a shared loco key. The older member is complete;
    // the newest member is broken across many fields. The collapsed card's
    // summary must surface the complete values from the older member, not
    // the broken newest ones.
    final complete = mkRecord(
      uniqueId: 'sum1',
      receivedMs: _base,
      loco: '41010559', // shared loco key -> merges with sum2
      train: '57908',
      lbjClass: 'K',
      speed: '50',
      time: '22:24',
      route: '京九线',
      positionInfo: '30°18.1522′ 120°10.9625′',
      direction: 1,
    );
    final broken = mkRecord(
      uniqueId: 'sum2',
      receivedMs: _base + 5 * _minute, // newest, within 1h
      loco: '41010559', // same loco -> merges
      train: '-----',
      direction: 3,
      speed: '',
      time: '<NUL>',
      route: '',
      positionInfo: '<NUL>',
      position: '----.-',
      lbjClass: '',
    );
    await DatabaseService.instance.insertRecord(complete);
    await DatabaseService.instance.insertRecord(broken);

    // itemContaining needs a non-time-only record; reuse the broken one.
    final item = await RecordsFeed.itemContaining(broken);
    expect(item, isNotNull);
    final merged = item as MergedTrainRecord;
    final s = merged.summaryRecord;

    expect(merged.recordCount, 2);
    expect(s.train, '57908');
    expect(s.lbjClass, 'K');
    expect(s.speed, '50');
    expect(s.time, '22:24');
    expect(s.loco, '41010559');
    expect(s.route, '京九线');
    expect(s.positionInfo, '30°18.1522′ 120°10.9625′');
    expect(s.direction, 1);
  });

  test('merged card keeps the lbjClass prefix when only an older member has it',
      () async {
    // The exact reported scenario: two records merge via train "11" within
    // 1h. The newer member has an empty lbjClass; the older carries "D".
    // The collapsed card's summary must show "D11", not "11".
    await DatabaseService.instance.insertRecord(mkRecord(
      uniqueId: '1782098408000_2451',
      receivedMs: 1782098408000,
      train: '11',
      lbjClass: 'D',
      loco: '24700331',
      locoType: 'FXD1-J',
      route: '笕杭',
      direction: 3,
      speed: '95',
      position: '195.4',
    ));
    await DatabaseService.instance.insertRecord(mkRecord(
      uniqueId: '1782098432000_8040',
      receivedMs: 1782098432000, // 24s later -> merges
      train: '11',
      lbjClass: '', // newer, no class
      direction: 3,
      speed: '101',
      position: '196.0',
    ));

    final item = await RecordsFeed.itemContaining(mkRecord(
      uniqueId: '1782098432000_8040',
      receivedMs: 1782098432000,
      train: '11',
    ));
    expect(item, isNotNull);
    final merged = item as MergedTrainRecord;
    final s = merged.summaryRecord;

    expect(merged.recordCount, 2);
    expect(s.train, '11');
    expect(s.lbjClass, 'D');
    expect(
      TrainRecord.computeFullTrainNumber(s.lbjClass, s.train),
      'D11',
      reason: 'the "D" class from the older member must survive the merge',
    );
  });
}
