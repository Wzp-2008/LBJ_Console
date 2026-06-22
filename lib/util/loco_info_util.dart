import 'package:flutter/services.dart';

import 'package:lbjconsole/util/loco_type_util.dart';

class LocoInfoUtil {
  static final List<LocoInfo> _locoData = [];
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      final csvData = await rootBundle.loadString('assets/loco_info.csv');
      final lines = csvData.split('\n');

      for (final line in lines) {
        if (line.trim().isEmpty) continue;

        final fields = _parseCsvLine(line);
        if (fields.length >= 4) {
          try {
            final model = fields[0];
            final start = int.parse(fields[1]);
            final end = int.parse(fields[2]);
            final owner = fields[3];
            final alias = fields.length > 4 ? fields[4] : '';
            final manufacturer = fields.length > 5 ? fields[5] : '';

            _locoData.add(LocoInfo(
              model: model,
              start: start,
              end: end,
              owner: owner,
              alias: alias,
              manufacturer: manufacturer,
            ));
          } catch (e) {}
        }
      }
      _initialized = true;
    } catch (e) {
      _initialized = true;
    }
  }

  static List<String> _parseCsvLine(String line) {
    final fields = <String>[];
    final buffer = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < line.length; i++) {
      final char = line[i];

      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        fields.add(buffer.toString().trim());
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }

    fields.add(buffer.toString().trim());
    return fields;
  }

  static int? _parseLocoNumber(String number) {
    final cleanNumber = number.trim().replaceAll('-', '').replaceAll(' ', '');
    if (cleanNumber.isEmpty) return null;

    if (cleanNumber.length <= 6) {
      return int.tryParse(cleanNumber);
    }

    return int.tryParse(cleanNumber.substring(cleanNumber.length - 4));
  }

  static String _formatInfo(LocoInfo info) {
    final buffer = StringBuffer(info.owner);
    if (info.alias.isNotEmpty) {
      buffer.write(' - ${info.alias}');
    }
    if (info.manufacturer.isNotEmpty) {
      buffer.write(' - ${info.manufacturer}');
    }
    return buffer.toString();
  }

  static LocoInfo? _findMatchingInfo(String model, int numberInt) {
    for (final info in _locoData) {
      if (info.model == model &&
          numberInt >= info.start &&
          numberInt <= info.end) {
        return info;
      }
    }
    return null;
  }

  /// Resolve owner info from raw loco number, aligned with [LocoTypeUtil.queryTypeNameAndId].
  static String? getLocoInfoForRecord({
    required String locoType,
    required String loco,
  }) {
    final locoNo = loco.trim();
    if (locoNo.isEmpty || locoNo == '<NUL>') return null;

    final parsed = LocoTypeUtil().queryTypeNameAndId(locoNo);
    if (parsed != null) {
      final result = getLocoInfoDisplay(parsed.$1, parsed.$2);
      if (result != null) return result;
    }

    final type = locoType.trim();
    if (type.isNotEmpty && type != '<NUL>') {
      return getLocoInfoDisplay(type, locoNo);
    }

    return null;
  }

  static LocoInfo? findLocoInfo(String model, String number) {
    if (!_initialized || model.isEmpty || number.isEmpty) {
      return null;
    }

    final numberInt = _parseLocoNumber(number);
    if (numberInt == null) return null;

    return _findMatchingInfo(model.trim(), numberInt);
  }

  static String? getLocoInfoDisplay(String model, String number) {
    if (_locoData.isEmpty) return null;

    final modelTrimmed = model.trim();
    final numberTrimmed = number.trim();

    if (modelTrimmed.isEmpty ||
        numberTrimmed.isEmpty ||
        numberTrimmed == '<NUL>') {
      return null;
    }

    final numberInt = _parseLocoNumber(numberTrimmed);
    if (numberInt == null) return null;

    final info = _findMatchingInfo(modelTrimmed, numberInt);
    if (info == null) return null;

    return _formatInfo(info);
  }
}

class LocoInfo {
  final String model;
  final int start;
  final int end;
  final String owner;
  final String alias;
  final String manufacturer;

  LocoInfo({
    required this.model,
    required this.start,
    required this.end,
    required this.owner,
    required this.alias,
    required this.manufacturer,
  });
}
