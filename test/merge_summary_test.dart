import 'package:flutter_test/flutter_test.dart';

import 'package:lbjconsole/models/train_record.dart';
import 'package:lbjconsole/services/merge_service.dart';

/// Pure unit tests for [MergeService.buildSummaryRecord] and the
/// "good value" predicate. No database involved.
TrainRecord _rec({
  required String uniqueId,
  required int receivedMs,
  String train = '',
  int direction = 0,
  String speed = '',
  String position = '',
  String time = '',
  String loco = '',
  String locoType = '',
  String lbjClass = '',
  String route = '',
  String positionInfo = '',
  double rssi = 0.0,
}) {
  return TrainRecord(
    uniqueId: uniqueId,
    timestamp: DateTime.fromMillisecondsSinceEpoch(receivedMs),
    receivedTimestamp: DateTime.fromMillisecondsSinceEpoch(receivedMs),
    train: train,
    direction: direction,
    speed: speed,
    position: position,
    time: time,
    loco: loco,
    locoType: locoType,
    lbjClass: lbjClass,
    route: route,
    positionInfo: positionInfo,
    rssi: rssi,
  );
}

void main() {
  group('MergeService.isGoodValue', () {
    const bad = [
      '', // empty
      '   ', // whitespace only
      '<NUL>',
      ' <NUL> ',
      'NA',
      'na',
      'NUL',
      '-----', // dash train placeholder
      '----.-', // dash/dot position placeholder
      '*****',
      '* * *',
      '-.-.-',
      '......',
      '///',
      // Per-character corruption markers (`*` = undecoded char) — the value
      // has real content but is partially corrupted, so a clean sibling value
      // should win.
      '笕杭****',
      '**杭线',
      '沪昆****',
      '85**',
      '30°**.****′',
      'D*',
    ];
    for (final v in bad) {
      test('rejects placeholder: ${v.isEmpty ? "(empty)" : v}', () {
        expect(MergeService.isGoodValue(v), isFalse,
            reason: '"$v" should be treated as broken');
      });
    }

    const good = [
      '57908',
      'K',
      'D',
      '0D',
      '京九线',
      '笕杭线',
      '30°18.1522′ 120°10.9625′',
      '5',
      '41010559',
      '120.5,30.1',
      '东风11',
      '22:24',
    ];
    for (final v in good) {
      test('accepts real value: $v', () {
        expect(MergeService.isGoodValue(v), isTrue,
            reason: '"$v" should be treated as good');
      });
    }
  });

  group('MergeService.buildSummaryRecord', () {
    test('broken newest + complete older -> uses the complete values', () {
      // Newest member is broken across many fields; an older member is
      // complete. The summary must surface the complete data.
      final records = [
        _rec(
          uniqueId: 'new',
          receivedMs: 1000,
          train: '-----',
          direction: 3,
          speed: '',
          time: '<NUL>',
          loco: '',
          route: '',
          positionInfo: '<NUL>',
          position: '----.-',
          lbjClass: '',
        ),
        _rec(
          uniqueId: 'old',
          receivedMs: 900,
          train: '57908',
          direction: 1,
          speed: '50',
          time: '22:24',
          loco: '41010559',
          route: '京九线',
          positionInfo: '30°18.1522′ 120°10.9625′',
          position: '120.5,30.1',
          lbjClass: 'K',
        ),
      ];
      final s = MergeService.buildSummaryRecord(records);

      expect(s.train, '57908');
      expect(s.lbjClass, 'K');
      expect(s.speed, '50');
      expect(s.time, '22:24');
      expect(s.loco, '41010559');
      expect(s.route, '京九线');
      expect(s.positionInfo, '30°18.1522′ 120°10.9625′');
      expect(s.position, '120.5,30.1');
      expect(s.direction, 1);
    });

    test('no complete record -> combines complete parts from each member',
        () {
      // Each member has exactly one good field; the summary must combine them.
      final records = [
        _rec(uniqueId: 'a', receivedMs: 1000, speed: '50'),
        _rec(uniqueId: 'b', receivedMs: 900, route: '沪昆线'),
        _rec(uniqueId: 'c', receivedMs: 800, loco: '13800347'),
      ];
      final s = MergeService.buildSummaryRecord(records);

      expect(s.speed, '50');
      expect(s.route, '沪昆线');
      expect(s.loco, '13800347');
    });

    test('dash/dot placeholders never leak into the summary', () {
      final records = [
        _rec(
          uniqueId: 'a',
          receivedMs: 1000,
          train: '-----',
          speed: '----.-',
          position: '----.-',
          loco: '-----',
          locoType: '----',
          route: '----.-',
          positionInfo: '-----',
          time: '<NUL>',
          lbjClass: 'NA',
        ),
      ];
      final s = MergeService.buildSummaryRecord(records);

      expect(s.train, '');
      expect(s.speed, '');
      expect(s.position, '');
      expect(s.loco, '');
      expect(s.locoType, '');
      expect(s.route, '');
      expect(s.positionInfo, '');
      expect(s.time, '');
      expect(s.lbjClass, '');
    });

    test('train + lbjClass come from the same best-train record', () {
      // a has a real full train number (K + 57908); b has a different class.
      // The summary must keep them as a consistent pair from a, not mix.
      final records = [
        _rec(
            uniqueId: 'b',
            receivedMs: 1000,
            train: '1234',
            lbjClass: 'D'), // different class, newer
        _rec(
            uniqueId: 'a',
            receivedMs: 900,
            train: '57908',
            lbjClass: 'K'), // consistent real full train
      ];
      final s = MergeService.buildSummaryRecord(records);

      // bestTrainRecord is the first record whose computeFullTrainNumber is
      // non-empty — here b (K/D both valid). train+lbjClass must both come
      // from the same record (b), producing a coherent full train number.
      expect(s.train, '1234');
      expect(s.lbjClass, 'D');
      expect(TrainRecord.computeFullTrainNumber(s.lbjClass, s.train), 'D1234');
    });

    test('a newer member with an empty lbjClass must not drop the class',
        () {
      // Reproduces the reported bug: two records merge (same train "11", same
      // loco within 1h). The NEWER member has train "11" but an EMPTY
      // lbjClass; the OLDER member carries the real class "D". The summary must
      // surface "D11", not degrade to "11".
      final records = [
        _rec(
          uniqueId: '1782098432000_8040',
          receivedMs: 1782098432000,
          train: '11',
          lbjClass: '', // newer, no class
          direction: 3,
          speed: '101',
          position: '196.0',
        ),
        _rec(
          uniqueId: '1782098408000_2451',
          receivedMs: 1782098408000,
          train: '11',
          lbjClass: 'D', // older, real class
          loco: '24700331',
          locoType: 'FXD1-J',
          route: '笕杭',
          direction: 3,
          speed: '95',
          position: '195.4',
        ),
      ];
      final s = MergeService.buildSummaryRecord(records);
      expect(s.train, '11');
      expect(s.lbjClass, 'D');
      expect(
        TrainRecord.computeFullTrainNumber(s.lbjClass, s.train),
        'D11',
        reason: 'the class prefix from the older member must survive',
      );
    });

    test('a star-corrupted route is skipped in favor of a clean sibling', () {
      // The reported 8503 scenario: 4 records merge (same train). Two carry a
      // clean route "笕杭线"; the others carry star-corrupted "笕杭****". The
      // summary must show "笕杭线", not "笕杭****".
      final records = [
        _rec(uniqueId: 'a', receivedMs: 4000, train: '8503', route: '笕杭****'),
        _rec(uniqueId: 'b', receivedMs: 3000, train: '8503', route: '笕杭线'),
        _rec(uniqueId: 'c', receivedMs: 2000, train: '8503', route: '笕杭****'),
        _rec(uniqueId: 'd', receivedMs: 1000, train: '8503', route: '笕杭线'),
      ];
      final s = MergeService.buildSummaryRecord(records);
      expect(s.route, '笕杭线',
          reason: 'star-corrupted route must not shadow the clean value');
    });

    test('a star-corrupted train is skipped in favor of a clean train', () {
      final records = [
        _rec(uniqueId: 'a', receivedMs: 1000, train: '85**', lbjClass: 'D'),
        _rec(uniqueId: 'b', receivedMs: 900, train: '8503', lbjClass: 'D'),
      ];
      final s = MergeService.buildSummaryRecord(records);
      expect(s.train, '8503');
      expect(s.lbjClass, 'D');
      expect(TrainRecord.computeFullTrainNumber(s.lbjClass, s.train), 'D8503');
    });

    test('star-corrupted positionInfo / loco are skipped', () {
      final records = [
        _rec(
          uniqueId: 'a',
          receivedMs: 1000,
          train: '8503',
          loco: '24700***',
          positionInfo: '30°**.****′ 120°**.****′',
        ),
        _rec(
          uniqueId: 'b',
          receivedMs: 900,
          train: '8503',
          loco: '24700331',
          positionInfo: '30°17.9731′ 120°10.9305′',
        ),
      ];
      final s = MergeService.buildSummaryRecord(records);
      expect(s.loco, '24700331');
      expect(s.positionInfo, '30°17.9731′ 120°10.9305′');
    });

    test('direction prefers 0/1 over 3 (未知)', () {
      final records = [
        _rec(uniqueId: 'a', receivedMs: 1000, direction: 3),
        _rec(uniqueId: 'b', receivedMs: 900, direction: 1),
      ];
      final s = MergeService.buildSummaryRecord(records);
      expect(s.direction, 1);
    });

    test('direction falls back to latest when only 3 is available', () {
      final records = [
        _rec(uniqueId: 'a', receivedMs: 1000, direction: 3),
        _rec(uniqueId: 'b', receivedMs: 900, direction: 3),
      ];
      final s = MergeService.buildSummaryRecord(records);
      expect(s.direction, 3);
    });

    test('time prefers a real value over <NUL> from the latest', () {
      final records = [
        _rec(uniqueId: 'a', receivedMs: 1000, time: '<NUL>'),
        _rec(uniqueId: 'b', receivedMs: 900, time: '22:24'),
      ];
      final s = MergeService.buildSummaryRecord(records);
      expect(s.time, '22:24');
    });

    test('route/positionInfo with real content survive a <NUL> newest member',
        () {
      final records = [
        _rec(
          uniqueId: 'a',
          receivedMs: 1000,
          route: '',
          positionInfo: '<NUL>',
        ),
        _rec(
          uniqueId: 'b',
          receivedMs: 900,
          route: '京九线',
          positionInfo: '30°18.1522′ 120°10.9625′',
        ),
      ];
      final s = MergeService.buildSummaryRecord(records);
      expect(s.route, '京九线');
      expect(s.positionInfo, '30°18.1522′ 120°10.9625′');
    });

    test('identity fields come from the latest member', () {
      final records = [
        _rec(
            uniqueId: 'latest-id',
            receivedMs: 1000,
            train: '57908',
            rssi: -80.0),
        _rec(uniqueId: 'older-id', receivedMs: 900, train: '57908', rssi: -99.0),
      ];
      final s = MergeService.buildSummaryRecord(records);
      // uniqueId/receivedTimestamp/rssi are the latest member's, so the card
      // key (m:groupKey is the *group* id, but the representative uniqueId)
      // and MapStateService keys stay stable.
      expect(s.uniqueId, 'latest-id');
      expect(
          s.receivedTimestamp.millisecondsSinceEpoch, 1000);
      expect(s.rssi, -80.0);
    });
  });
}
