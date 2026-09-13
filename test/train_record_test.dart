import 'package:flutter_test/flutter_test.dart';
import 'package:lbjconsole/models/train_record.dart';

TrainRecord _record({
  int direction = 0,
  String train = '',
  String lbjClass = '',
  String loco = '',
  String locoType = '',
  String route = '',
  String positionInfo = '',
}) {
  final timestamp = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  return TrainRecord(
    uniqueId: 'record-1',
    timestamp: timestamp,
    receivedTimestamp: timestamp,
    train: train,
    direction: direction,
    speed: '',
    position: '',
    time: '',
    loco: loco,
    locoType: locoType,
    lbjClass: lbjClass,
    route: route,
    positionInfo: positionInfo,
    rssi: -70,
  );
}

void main() {
  group('TrainRecord wire and display normalization', () {
    test('normalizes unknown direction values and exposes display labels', () {
      expect(TrainRecord.normalizeDirection(1), 1);
      expect(TrainRecord.normalizeDirection(3), 3);
      expect(TrainRecord.normalizeDirection(2), 0);

      expect(_record(direction: 1).directionText, '下行');
      expect(_record(direction: 1).directionBadge, '下');
      expect(_record(direction: 3).directionText, '上行');
      expect(_record(direction: 3).directionBadge, '上');
      expect(_record(direction: 9).directionText, '未知');
      expect(_record(direction: 9).directionBadge, isNull);
    });

    test('fromJson accepts legacy aliases and numeric strings', () {
      final record = TrainRecord.fromJson({
        'unique_id': '  legacy-1 ',
        'timestamp': '1700000000000',
        'received_timestamp': 1700000001000,
        'train': 'K1234',
        'dir': '3',
        'speed': '80',
        'pos': '195.7',
        'loco_type': '东风4',
        'lbj_class': 'K',
        'position_info': '京九线',
        'rssi': '-65.5',
      });

      expect(record.uniqueId, 'legacy-1');
      expect(record.direction, 3);
      expect(record.receivedTimestamp.millisecondsSinceEpoch, 1700000001000);
      expect(record.position, '195.7');
      expect(record.locoType, '东风4');
      expect(record.lbjClass, 'K');
      expect(record.rssi, -65.5);
    });

    test(
      'search text removes placeholders and normalizes searchable tokens',
      () {
        final text = TrainRecord.buildSearchText(
          lbjClass: ' K ',
          train: ' 12-34 ',
          locoType: '东风4',
          loco: ' 4101 ',
          route: '<NUL>',
          positionInfo: '京九线',
        );

        expect(text, contains('k1234'));
        expect(text, contains('1234'));
        expect(text, contains('东风4'));
        expect(text, contains('4101'));
        expect(text, contains('京九线'));
        expect(text, isNot(contains('<nul>')));
        expect(TrainRecord.computeFullTrainNumber('NA', ' Z900 '), 'Z900');
        expect(TrainRecord.computeFullTrainNumber('K', '<NUL>'), isEmpty);
      },
    );

    test('derived grouping columns reject corrupted values', () {
      final invalid = _record(train: '(1234', loco: '85**');
      expect(invalid.trainKey, isNull);
      expect(invalid.locoKey, isNull);
      expect(invalid.isTimeOnly, isTrue);
      expect(invalid.derivedColumns(), {
        'isTimeOnly': 1,
        'trainKey': null,
        'locoKey': null,
      });

      final valid = _record(
        train: '1234',
        lbjClass: 'K',
        loco: '41010559',
        locoType: '东风4',
        route: '京九线',
        positionInfo: '30N',
      );
      expect(valid.trainKey, '1234');
      expect(valid.locoKey, '41010559');
      expect(valid.isTimeOnly, isFalse);
      expect(valid.toDatabaseJson()['searchText'], contains('k1234'));
    });
  });
}
