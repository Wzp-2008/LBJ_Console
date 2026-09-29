import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'helpers.dart';

void main() {
  late dynamic db;
  setUp(() async {
    db = await initTestDb();
    await DatabaseService.instance.updateSettings({'mergeRecordsEnabled': 1});
  });
  tearDown(disposeTestDatabase);

  TrainRecord record(String id, int minute, String train, [String loco = '']) =>
      mkRecord(
        uniqueId: id,
        receivedMs: 1700000000000 + minute * 60000,
        train: train,
        loco: loco,
        direction: 1,
      );

  Future<Set<String>> groups() async {
    final page = await RecordsFeed.fetchPage(limit: 1000);
    return page.items.map((item) {
      final ids = item is MergedTrainRecord
          ? item.memberUniqueIds.toList()
          : [(item as TrainRecord).uniqueId];
      ids.sort();
      return ids.join(',');
    }).toSet();
  }

  test('batch deletion never merges unrelated surviving groups', () async {
    for (final r in [
      record('a', 0, 'T1'),
      record('b', 1, 'T1'),
      record('c', 0, 'T2'),
      record('d', 1, 'T2'),
    ]) {
      await DatabaseService.instance.insertRecord(r);
    }
    await DatabaseService.instance.deleteRecords(['b', 'd']);
    expect(await groups(), {'a', 'c'});
    expect(
      await DisplayGroupCache.needsRebuild(
        db,
        recordsTable: DatabaseService.trainRecordsTable,
      ),
      isFalse,
    );
  });

  test(
    'deleting a bridge splits keys and deleting a time bridge splits sessions',
    () async {
      for (final r in [
        record('a', 0, 'T1'),
        record('bridge', 1, 'T1', 'L1'),
        record('b', 2, '', 'L1'),
        record('x', 0, 'T2'),
        record('timeBridge', 60, 'T2'),
        record('y', 120, 'T2'),
      ]) {
        await DatabaseService.instance.insertRecord(r);
      }
      await DatabaseService.instance.deleteRecords(['bridge', 'timeBridge']);
      expect(await groups(), {'a', 'b', 'x', 'y'});
    },
  );

  test('key expiration agrees across live inserts and rebuild', () async {
    for (final r in [
      record('a', 0, 'T1', 'L1'),
      record('b', 50, 'T2', 'L1'),
      record('c', 100, 'T2', 'L1'),
      record('d', 110, 'T1'),
    ]) {
      await DatabaseService.instance.insertRecord(r);
    }
    expect(await groups(), {'a,b,c', 'd'});
    await DatabaseService.instance.rebuildMergeCache();
    expect(await groups(), {'a,b,c', 'd'});
  });

  test('out-of-order inserts and replacements match full grouping', () async {
    final random = Random(7);
    final records = List.generate(
      90,
      (i) => record(
        'r$i',
        random.nextInt(400),
        'T${random.nextInt(8)}',
        i % 3 == 0 ? 'L${random.nextInt(5)}' : '',
      ),
    );
    records.shuffle(random);
    for (final r in records) {
      await DatabaseService.instance.insertRecord(r);
    }
    for (var i = 0; i < 10; i++) {
      final replacement = record(records[i].uniqueId, 1000 + i * 70, 'NEW$i');
      records[i] = replacement;
      await DatabaseService.instance.insertRecord(replacement);
    }
    final expected = groupRecordsIntoPayload(records).map((g) {
      final ids = List<String>.from(g['memberIds'] as List)..sort();
      return ids.join(',');
    }).toSet();
    expect(await groups(), expected);
  });

  test(
    'append writes one membership and keeps summary equivalent to rebuild',
    () async {
      final records = List.generate(
        250,
        (i) => mkRecord(
          uniqueId: 'r${i.toString().padLeft(4, '0')}',
          receivedMs: 1700000000000 + i * 1000,
          train: i % 4 == 0 ? '11' : '',
          lbjClass: i % 8 == 0 ? 'D' : '',
          loco: 'L1',
          speed: i % 3 == 0 ? '$i' : '',
          direction: i % 2 == 0 ? 3 : 0,
          route: i % 5 == 0 ? '路线' : '',
        ),
      );
      for (final r in records) {
        await DatabaseService.instance.insertRecord(r);
      }
      await db.execute('CREATE TABLE member_write_count (n INTEGER)');
      await db.execute('INSERT INTO member_write_count VALUES (0)');
      await db.execute(
        'CREATE TRIGGER count_member_insert AFTER INSERT ON merge_display_members '
        'BEGIN UPDATE member_write_count SET n = n + 1; END',
      );
      await db.execute(
        'CREATE TRIGGER count_member_delete AFTER DELETE ON merge_display_members '
        'BEGIN UPDATE member_write_count SET n = n + 1; END',
      );
      final next = record('next', 5, '11', 'L1');
      await DatabaseService.instance.insertRecord(next);
      final writes = await db.rawQuery('SELECT n FROM member_write_count');
      expect(
        writes.single['n'],
        1,
        reason: 'Appending must not rewrite existing members',
      );
      final before =
          await RecordsFeed.itemContaining(next) as MergedTrainRecord;
      final summary = before.summaryRecord.toTransferJson();
      await DatabaseService.instance.rebuildMergeCache();
      final after = await RecordsFeed.itemContaining(next) as MergedTrainRecord;
      expect(after.summaryRecord.toTransferJson(), summary);
      expect(after.recordCount, 251);
    },
  );

  test('timestamp ties choose a deterministic latest record', () async {
    await DatabaseService.instance.insertRecord(record('z', 0, 'T1'));
    await DatabaseService.instance.insertRecord(record('a', 0, 'T1'));
    final before =
        (await RecordsFeed.fetchPage(limit: 1)).items.single
            as MergedTrainRecord;
    await DatabaseService.instance.rebuildMergeCache();
    final after =
        (await RecordsFeed.fetchPage(limit: 1)).items.single
            as MergedTrainRecord;
    expect(before.latestRecord.uniqueId, 'z');
    expect(after.latestRecord.uniqueId, 'z');
  });
}
