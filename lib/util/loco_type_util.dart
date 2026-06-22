import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

class LocoTypeUtil {
  static final LocoTypeUtil _instance = LocoTypeUtil._internal();

  factory LocoTypeUtil() => _instance;

  LocoTypeUtil._internal() {
    _syncInitialize();
  }

  final Map<String, String> _locoTypeMap = {};
  bool _isInitialized = false;

  void _syncInitialize() {
    try {
      rootBundle.loadString('assets/loco_type_info.csv').then((csvData) {
        final lines = const LineSplitter().convert(csvData);
        for (final line in lines) {
          final trimmedLine = line.trim();
          if (trimmedLine.isEmpty) continue;
          final parts = trimmedLine.split(',');
          if (parts.length >= 2) {
            final code = parts[0].trim();
            final type = parts[1].trim();
            _locoTypeMap[code] = type;
          }
        }
        _isInitialized = true;
      });
    } catch (e) {}
  }

  @deprecated
  Future<void> initialize() async {}

  String? getLocoTypeByCode(String code) {
    if (_locoTypeMap.containsKey(code)) {
      return _locoTypeMap[code];
    }

    if (code.length >= 4) {
      final prefix3 = code.substring(0, 3);
      return _locoTypeMap[prefix3];
    }

    return null;
  }

  String? getLocoTypeByLocoNumber(String locoNumber) {
    final parsed = queryTypeNameAndId(locoNumber);
    return parsed?.$1;
  }

  static const int _crLocoIdLength = 4;

  static (String, String) _parseCrLoco(
    String typeName,
    String locoNo,
    int prefixLen,
  ) {
    final idStart = prefixLen;
    final idEnd = idStart + _crLocoIdLength;
    if (locoNo.length >= idEnd) {
      return (typeName, locoNo.substring(idStart, idEnd));
    }
    if (locoNo.length > idStart) {
      return (typeName, locoNo.substring(idStart));
    }
    return (typeName, '');
  }

  /// Returns [typeName, locoId] parsed from the full loco number string.
  (String, String)? queryTypeNameAndId(String locoNo) {
    if (locoNo.isEmpty) return null;

    if (locoNo.length >= 4) {
      final firstFour = locoNo.substring(0, 4);
      final fourValueName = _locoTypeMap[firstFour];
      if (fourValueName != null) {
        if (fourValueName.startsWith('CR')) {
          return _parseCrLoco(fourValueName, locoNo, 4);
        }
        return (fourValueName, locoNo.substring(4));
      }
    }

    if (locoNo.length >= 3) {
      final firstThird = locoNo.substring(0, 3);
      final thirdValueName = _locoTypeMap[firstThird];
      if (thirdValueName != null) {
        if (thirdValueName.startsWith('CR')) {
          return _parseCrLoco(thirdValueName, locoNo, 3);
        }
        if (thirdValueName.startsWith('G') || thirdValueName.contains('轨道车')) {
          return (thirdValueName, locoNo.substring(3));
        }
        return (thirdValueName, locoNo.length >= 4 ? locoNo.substring(4) : '');
      }
    }

    return null;
  }

  String queryDisplayName(String locoNo) {
    final queryRes = queryTypeNameAndId(locoNo);
    if (queryRes == null) {
      return locoNo;
    }
    return '${queryRes.$1}-${queryRes.$2}';
  }

  static String formatLocoDisplay(String locoType, String loco) {
    final locoNo = loco.trim();
    if (locoNo.isNotEmpty && locoNo != '<NUL>') {
      return LocoTypeUtil().queryDisplayName(locoNo);
    }
    final type = locoType.trim();
    if (type.isNotEmpty && type != '<NUL>') {
      return type;
    }
    return '';
  }

  Map<String, String> getAllMappings() {
    return Map.from(_locoTypeMap);
  }

  bool get isInitialized => _isInitialized;

  int get mappingCount => _locoTypeMap.length;
}
