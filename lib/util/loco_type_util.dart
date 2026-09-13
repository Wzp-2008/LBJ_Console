import 'dart:async';

import 'package:flutter/services.dart';
import 'csv_parser.dart';

class LocoTypeUtil {
  static final LocoTypeUtil _instance = LocoTypeUtil._internal();

  factory LocoTypeUtil() => _instance;

  LocoTypeUtil._internal() {
    _initialization = _loadMappings();
  }

  final Map<String, String> _locoTypeMap = {};
  late final Future<void> _initialization;

  Future<void> _loadMappings() async {
    try {
      final csvData = await rootBundle.loadString('assets/loco_type_info.csv');
      _locoTypeMap.addAll(parseLocoTypeMap(csvData));
    } catch (_) {
      // An unavailable optional asset leaves lookups as a safe pass-through.
    }
  }

  Future<void> initialize() => _initialization;

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
        return (thirdValueName, locoNo.substring(3));
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
}
