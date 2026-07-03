import 'dart:convert';
import 'dart:io';

import 'package:gbk_codec/gbk_codec.dart';

/// Outcome of importing CSV files from a Windows drive.
class CsvImportResult {
  final bool success;
  final int fileCount;
  final int recordCount;
  final String message;

  const CsvImportResult({
    required this.success,
    this.fileCount = 0,
    this.recordCount = 0,
    required this.message,
  });
}

/// Header columns of the LBJ CSV rows, in order. Mirrors the `header` string
/// in `csv_json.py`: line 0 is a comment, line 1 is the header, line 2+ is
/// data — we skip the first two lines and parse every data row against this
/// fixed header (the on-disk header is ignored, exactly as the Python does).
const List<String> _kHeaders = [
  '温度', '电压', '系统时间', '日期', '时间', 'LBJ时间', '方向', '级别', '车次',
  '速度', '公里标', '机车编号', '线路', '纬度', '经度', 'HEX', 'RSSI', 'FER',
  'PPM(FER)', 'PPM(CURRENT)', '原始数据', '错误', '错误率',
];

/// Direction code mapping, matching `direction_map` in `csv_json.py`. The app
/// stores 上行 as 1 and 下行 as 3 (same convention the Python-written
/// `LBJ_Console_output.json` uses, which the JSON import already consumes),
/// so CSV-imported records line up with JSON-imported ones.
const Map<String, int> _kDirectionMap = {'上行': 1, '下行': 3};

/// Top-level entry for [compute]: reads every CSV file in `input['files']`
/// (trying utf-8 then gbk, the same fallback order as `csv_json.py`'s
/// utf-8 → gb18030 → gbk), parses each data row into a train-record map, and
/// returns `{'records': [...]}` sorted by timestamp descending.
///
/// This is a faithful Dart port of `merge_and_convert` in `csv_json.py`:
/// - [parseCsvLine] mirrors `parse_csv_line` (quoted-field aware).
/// - [_clean] mirrors `clean` (strips `<NUL>` / `null` / `NA` / `NUL` / `********`).
/// - [_parseFloat] mirrors `parse_float` (0.0 on NaN/Inf/parse failure).
/// - [_getLocoType] mirrors `get_loco_type` (4-char then 3-char prefix lookup),
///   adapted from Python's `int`-keyed `train.xlsx` to the string-keyed
///   `loco_type_info.csv` asset (`input['locoTypeMap']`, loaded on the main
///   isolate since isolates cannot touch `rootBundle`).
/// - Timestamps are built from the 日期 + 时间 columns as UTC+8 wall-clock,
///   matching `datetime.strptime(...).replace(tzinfo=UTC8).timestamp()`.
///
/// `locoTypeMap` is passed in (rather than read via `rootBundle` here) because
/// this runs in a worker isolate with no Flutter binding. Returned as a
/// `Map<String, dynamic>` (`{'records': [...]}`) so the receiving side can
/// re-type the nested list with `.cast`, exactly like `prepareImportPayload`.
Map<String, dynamic> parseCsvFilesToRecords(Map<String, dynamic> input) {
  final files = (input['files'] as List).cast<String>();
  final locoTypeMap = Map<String, String>.from(input['locoTypeMap'] as Map);

  final records = <Map<String, dynamic>>[];
  // Per-import counter guarantees unique uniqueIds even when many rows share
  // a timestamp (the Python script uses random 0..9999, which can collide and
  // silently drop rows under REPLACE); a monotonic suffix avoids that.
  var seq = 0;

  for (final path in files) {
    final text = _decodeFile(path);
    if (text == null) continue; // unknown encoding → skip (matches Python)

    final lines = text.split('\n');
    // Line 0: comment, Line 1: header, Line 2+: data.
    for (var i = 2; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (line.runes.every((c) => c == 0x2C)) continue; // all commas

      final fields = _parseCsvLine(line);
      if (fields.length < 16) continue;

      final data = <String, String>{};
      for (var h = 0; h < _kHeaders.length && h < fields.length; h++) {
        data[_kHeaders[h]] = fields[h];
      }

      // Only keep rows with a complete date AND time (used for the timestamp).
      final dateStr = _clean(data['日期'] ?? '');
      final timeStr = _clean(data['时间'] ?? '');
      if (dateStr.isEmpty || timeStr.isEmpty) continue;

      final directionStr = _clean(data['方向'] ?? '');
      final direction = _kDirectionMap[directionStr] ?? 0;

      final timestamp = _parseTimestampUtc8(dateStr, timeStr);
      if (timestamp == 0) continue; // malformed date/time → skip (robust)

      final lat = _clean(data['纬度'] ?? '');
      final lon = _clean(data['经度'] ?? '');
      final posSrc = '$lat $lon'.trim();
      final positionInfo = posSrc.isEmpty ? '<NUL>' : posSrc;

      final rssi = _parseFloat(data['RSSI'] ?? '0');
      final loco = _clean(data['机车编号'] ?? '');
      final lbjTime = _clean(data['LBJ时间'] ?? '');

      records.add({
        'uniqueId': '${timestamp}_${seq.toString().padLeft(4, '0')}',
        'timestamp': timestamp,
        'receivedTimestamp': timestamp,
        'train': _clean(data['车次'] ?? ''),
        'direction': direction,
        'speed': _clean(data['速度'] ?? ''),
        'position': _clean(data['公里标'] ?? ''),
        'time': lbjTime.isEmpty ? '<NUL>' : lbjTime,
        'loco': loco,
        'locoType': _getLocoType(loco, locoTypeMap),
        'lbjClass': _clean(data['级别'] ?? ''),
        'route': _clean(data['线路'] ?? ''),
        'positionInfo': positionInfo,
        'rssi': rssi,
      });
      seq++;
    }
  }

  // Sort by timestamp descending — same as `records.sort(key=lambda r: r["timestamp"], reverse=True)`.
  records.sort((a, b) =>
      (b['timestamp'] as int).compareTo(a['timestamp'] as int));
  return <String, dynamic>{'records': records};
}

/// Read [path] as text, trying utf-8 (strict) then GBK. `csv_json.py` tries
/// utf-8 → gb18030 → gbk; `gbk_codec` ships GBK, which covers the same Chinese
/// CSVs in practice (gb18030 is a superset rarely used for these files).
///
/// Uses `gbk_bytes` (not the package's `gbk`): `gbk_bytes` combines 2-byte
/// GBK sequences, whereas `gbk` decodes byte-by-byte and mis-decodes Chinese.
/// Returns null when neither decodes so the caller skips the file, matching
/// Python's "Skipping ...: unknown encoding".
String? _decodeFile(String path) {
  final bytes = File(path).readAsBytesSync();
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } catch (_) {}
  try {
    return gbk_bytes.decode(bytes);
  } catch (_) {}
  return null;
}

/// Parse a CSV line, honouring quoted fields that may contain commas.
/// Direct port of `parse_csv_line` in `csv_json.py`.
List<String> _parseCsvLine(String line) {
  final fields = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (final c in line.runes) {
    if (c == 0x22) {
      // "
      inQuotes = !inQuotes;
    } else if (c == 0x2C && !inQuotes) {
      // ,
      fields.add(buf.toString());
      buf.clear();
    } else {
      buf.writeCharCode(c);
    }
  }
  fields.add(buf.toString());
  return fields;
}

/// Strip placeholder tokens. Direct port of `clean` in `csv_json.py`.
String _clean(String value) {
  var v = value.trim();
  for (final token in ['<NUL>', 'null', 'NA', 'NUL', '********']) {
    v = v.replaceAll(token, '');
  }
  return v;
}

/// Parse a double, returning 0.0 for NaN/Inf/failure. Port of `parse_float`.
double _parseFloat(String value) {
  try {
    final v = double.parse(value.trim());
    if (v.isNaN || v.isInfinite) return 0.0;
    return v;
  } catch (_) {
    return 0.0;
  }
}

/// Resolve loco type from the loco number by prefix lookup (4-char then
/// 3-char) in the type map. Faithful string-keyed adaptation of
/// `get_loco_type` in `csv_json.py` (which uses `int(prefix)` against
/// `train.xlsx`); here the map is `loco_type_info.csv` with string codes, so
/// the raw prefix string is the key.
String _getLocoType(String locoNumber, Map<String, String> mapping) {
  if (locoNumber.isEmpty || locoNumber.length < 3) return '';
  if (locoNumber.length >= 4) {
    final t = mapping[locoNumber.substring(0, 4)];
    if (t != null) return t;
  }
  return mapping[locoNumber.substring(0, 3)] ?? '';
}

/// Build a UTC epoch-millis timestamp from a `YYYY-MM-DD HH:MM:SS` wall-clock
/// interpreted as UTC+8 — the same instant `csv_json.py` produces via
/// `datetime.strptime(...).replace(tzinfo=UTC8).timestamp()`. Returns 0 on
/// malformed input so the caller can skip the row (Python would crash; we
/// skip to keep one bad row from aborting the whole import).
int _parseTimestampUtc8(String dateStr, String timeStr) {
  try {
    final dp = dateStr.split('-');
    final tp = timeStr.split(':');
    if (dp.length < 3 || tp.length < 3) return 0;
    final wallClock = DateTime.utc(
      int.parse(dp[0]),
      int.parse(dp[1]),
      int.parse(dp[2]),
      int.parse(tp[0]),
      int.parse(tp[1]),
      int.parse(tp[2]),
    );
    // wall-clock was UTC+8; the true UTC instant is 8 hours earlier.
    return wallClock.subtract(const Duration(hours: 8)).millisecondsSinceEpoch;
  } catch (_) {
    return 0;
  }
}
