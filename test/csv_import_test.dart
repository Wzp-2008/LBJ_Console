import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:lbjconsole/services/csv_import_service.dart';
import 'package:path/path.dart' as p;

const String _kHeader =
    '温度,电压,系统时间,日期,时间,LBJ时间,方向,级别,车次,速度,公里标,机车编号,线路,纬度,经度,HEX,RSSI,FER,PPM(FER),PPM(CURRENT),原始数据,错误,错误率';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('csv_import_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File writeCsv(String name, String content) {
    final f = File(p.join(tempDir.path, name));
    f.writeAsStringSync(content);
    return f;
  }

  /// Two data rows (上行 then 下行); expect descending-by-timestamp order so
  /// the 下行 row (12:01) comes out first.
  test('parses rows, resolves locoType by prefix, sorts by timestamp desc',
      () {
    final csv = '#LBJ export\n$_kHeader\n'
        '25.0,12.5,2024-01-01 12:00:00,2024-01-01,12:00:00,12:00:00,上行,G,K1,120,100,1041234,京沪线,30.5,120.2,AB,-80,0,0,0,raw,0,0\n'
        '26.0,12.6,2024-01-01 12:01:00,2024-01-01,12:01:00,12:01:00,下行,G,K2,130,200,0001234,京沪线,30.6,120.3,CD,-70,0,0,0,raw,0,0\n';
    final file = writeCsv('CSV_001.csv', csv);

    final result = parseCsvFilesToRecords({
      'files': [file.path],
      'locoTypeMap': <String, String>{'000': '未知测试车型', '104': '东风4'},
    });
    final records = (result['records'] as List).cast<Map<String, dynamic>>();
    expect(records.length, 2);

    // Descending: 12:01:00 first.
    expect(records[0]['train'], 'K2');
    expect(records[0]['direction'], 3); // 下行
    expect(records[0]['locoType'], '未知测试车型'); // 000 prefix (0001 miss → 000)
    expect(records[0]['positionInfo'], '30.6 120.3');
    expect(records[0]['rssi'], -70.0);

    expect(records[1]['train'], 'K1');
    expect(records[1]['direction'], 1); // 上行
    expect(records[1]['locoType'], '东风4'); // 104 prefix (1041 miss → 104)
    // 2024-01-01 12:00:00 UTC+8 == 04:00:00 UTC.
    final expectedTs =
        DateTime.utc(2024, 1, 1, 4, 0, 0).millisecondsSinceEpoch;
    expect(records[1]['timestamp'], expectedTs);
    expect(records[1]['receivedTimestamp'], expectedTs);
    // K1 is emitted first (seq=0) even though it sorts second.
    expect(records[1]['uniqueId'], '${expectedTs}_0000');
  });

  test('skips rows missing date or time', () {
    final csv = '#c\n$_kHeader\n'
        '25.0,12.5,2024-01-01 12:00:00,,12:00:00,12:00:00,上行,G,K1,120,100,1041234,京沪线,30.5,120.2,AB,-80,0,0,0,raw,0,0\n'
        '26.0,12.6,2024-01-01 12:01:00,2024-01-01,,12:01:00,下行,G,K2,130,200,0001234,京沪线,30.6,120.3,CD,-70,0,0,0,raw,0,0\n';
    final file = writeCsv('CSV_002.csv', csv);
    final result = parseCsvFilesToRecords({
      'files': [file.path],
      'locoTypeMap': <String, String>{'104': '东风4'},
    });
    final records = (result['records'] as List).cast<Map<String, dynamic>>();
    expect(records.length, 0);
  });

  test('skips all-comma and empty data lines', () {
    final csv = '#c\n$_kHeader\n'
        ',,,,,,,,,,,,,,,,,,,,,,,\n'
        '\n'
        '25.0,12.5,2024-01-01 12:00:00,2024-01-01,12:00:00,12:00:00,上行,G,K1,120,100,1041234,京沪线,30.5,120.2,AB,-80,0,0,0,raw,0,0\n';
    final file = writeCsv('CSV_003.csv', csv);
    final result = parseCsvFilesToRecords({
      'files': [file.path],
      'locoTypeMap': <String, String>{'104': '东风4'},
    });
    final records = (result['records'] as List).cast<Map<String, dynamic>>();
    expect(records.length, 1);
    expect(records[0]['train'], 'K1');
  });

  // Verifies the isolate round-trip: a `compute` spawn must return records
  // whose maps re-type cleanly to Map<String, dynamic> (the same shape
  // importRawRecords feeds into prepareImportPayload / TrainRecord.fromJson).
  test('compute round-trip preserves record shape', () async {
    final csv = '#c\n$_kHeader\n'
        '25.0,12.5,2024-01-01 12:00:00,2024-01-01,12:00:00,12:00:00,上行,G,K1,120,100,1041234,京沪线,30.5,120.2,AB,-80,0,0,0,raw,0,0\n';
    final file = writeCsv('CSV_004.csv', csv);
    final payload = await compute<Map<String, dynamic>, Map<String, dynamic>>(
      parseCsvFilesToRecords,
      <String, dynamic>{
        'files': [file.path],
        'locoTypeMap': <String, String>{'104': '东风4'},
      },
    );
    final records = (payload['records'] as List).cast<Map<String, dynamic>>();
    expect(records.length, 1);
    expect(records[0]['train'], 'K1');
    expect(records[0]['locoType'], '东风4');
    expect(records[0]['rssi'], -80.0);
    expect(records[0]['direction'], 1);
  });

  // Real LBJ CSV exports are often GBK-encoded; verify the utf-8 → gbk
  // fallback decodes them correctly.
  test('decodes GBK-encoded files via the utf-8 → gbk fallback', () {
    final csv = '#c\n$_kHeader\n'
        '25.0,12.5,2024-01-01 12:00:00,2024-01-01,12:00:00,12:00:00,上行,G,K1,120,100,1041234,京沪线,30.5,120.2,AB,-80,0,0,0,raw,0,0\n';
    final file = File(p.join(tempDir.path, 'CSV_005.csv'))
      ..writeAsBytesSync(gbk_bytes.encode(csv));
    final result = parseCsvFilesToRecords({
      'files': [file.path],
      'locoTypeMap': <String, String>{'104': '东风4'},
    });
    final records = (result['records'] as List).cast<Map<String, dynamic>>();
    expect(records.length, 1);
    expect(records[0]['train'], 'K1');
    expect(records[0]['route'], '京沪线'); // would be garbage if mis-decoded
    expect(records[0]['direction'], 1); // 上行
  });
}
