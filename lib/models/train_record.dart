import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:lbjconsole/util/train_type_util.dart';
import 'package:lbjconsole/util/loco_info_util.dart';
import 'package:lbjconsole/util/loco_type_util.dart';

class TrainRecord {
  final String uniqueId;
  final DateTime timestamp;
  final DateTime receivedTimestamp;
  final String train;
  final int direction;
  final String speed;
  final String position;
  final String time;
  final String loco;
  final String locoType;
  final String lbjClass;
  final String route;
  final String positionInfo;
  final double rssi;

  TrainRecord({
    required this.uniqueId,
    required this.timestamp,
    required this.receivedTimestamp,
    required this.train,
    required this.direction,
    required this.speed,
    required this.position,
    required this.time,
    required this.loco,
    required this.locoType,
    required this.lbjClass,
    required this.route,
    required this.positionInfo,
    required this.rssi,
  });

  factory TrainRecord.fromJson(Map<String, dynamic> json) {
    return TrainRecord(
      uniqueId: json['uniqueId'] ?? json['unique_id'] ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] ?? 0),
      receivedTimestamp: DateTime.fromMillisecondsSinceEpoch(
          json['receivedTimestamp'] ?? json['received_timestamp'] ?? 0),
      train: json['train'] ?? '',
      direction: json['direction'] ?? json['dir'] ?? 0,
      speed: json['speed'] ?? '',
      position: json['position'] ?? json['pos'] ?? '',
      time: json['time'] ?? '',
      loco: json['loco'] ?? '',
      locoType: json['locoType'] ?? json['loco_type'] ?? '',
      lbjClass: json['lbjClass'] ?? json['lbj_class'] ?? '',
      route: json['route'] ?? '',
      positionInfo: json['positionInfo'] ?? json['position_info'] ?? '',
      rssi: (json['rssi'] ?? 0.0).toDouble(),
    );
  }

  factory TrainRecord.fromJsonString(String jsonString) {
    final json = jsonDecode(jsonString);
    return TrainRecord.fromJson(json);
  }

  Map<String, dynamic> toJson() {
    return {
      'uniqueId': uniqueId,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'receivedTimestamp': receivedTimestamp.millisecondsSinceEpoch,
      'train': train,
      'direction': direction,
      'speed': speed,
      'position': position,
      'time': time,
      'loco': loco,
      'loco_type': locoType,
      'lbj_class': lbjClass,
      'route': route,
      'position_info': positionInfo,
      'rssi': rssi,
    };
  }

  static bool _isMeaningfulSearchToken(String value) {
    if (value.isEmpty || value == '<NUL>' || value == 'NUL') return false;
    final cleaned = value.replaceAll('<NUL>', '').trim();
    if (cleaned.isEmpty || cleaned.contains('-----')) return false;
    if (cleaned.runes.every((r) => r == '*'.runes.first || r == ' '.runes.first)) {
      return false;
    }
    return true;
  }

  static String? _normalizeSearchToken(String value) {
    if (!_isMeaningfulSearchToken(value)) return null;
    return value.replaceAll('<NUL>', '').replaceAll('-', '').trim().toLowerCase();
  }

  static String computeFullTrainNumber(String lbjClass, String train) {
    final lbjClassValue = lbjClass.trim();
    final trainValue = train.trim();
    if (trainValue == '<NUL>' || trainValue.contains('-----')) {
      return '';
    }
    if (lbjClassValue.isEmpty || lbjClassValue == 'NA') {
      return trainValue;
    }
    return '$lbjClassValue$trainValue';
  }

  static String buildSearchText({
    required String lbjClass,
    required String train,
    required String locoType,
    required String loco,
    String route = '',
    String positionInfo = '',
  }) {
    final tokens = <String>{};
    void add(String? value) {
      final token = value == null ? null : _normalizeSearchToken(value);
      if (token != null && token.isNotEmpty) {
        tokens.add(token);
      }
    }

    add(computeFullTrainNumber(lbjClass, train));
    add(lbjClass + train);
    add(train);
    add(lbjClass);
    add(locoType + loco);
    add(locoType);
    add(loco);
    add(route);
    add(positionInfo);

    return tokens.join(' ');
  }

  /// Whether [normalizedQuery] is already lower-case with dashes removed.
  static bool matchesSearchQuery(TrainRecord record, String normalizedQuery) {
    if (normalizedQuery.isEmpty) return false;

    bool containsNormalized(String value) {
      final token = _normalizeSearchToken(value);
      return token != null && token.contains(normalizedQuery);
    }

    if (containsNormalized(computeFullTrainNumber(record.lbjClass, record.train))) {
      return true;
    }
    if (containsNormalized(record.lbjClass + record.train)) return true;
    if (containsNormalized(record.route)) return true;
    if (containsNormalized(record.positionInfo)) return true;

    final trainLike = RegExp(r'^[a-z]{1,4}\d+$').hasMatch(normalizedQuery);
    if (!trainLike) {
      if (containsNormalized(record.locoType + record.loco)) return true;
      if (containsNormalized(record.loco)) return true;
      if (record.searchText.toLowerCase().contains(normalizedQuery)) return true;
    }

    return false;
  }

  String get searchText => buildSearchText(
        lbjClass: lbjClass,
        train: train,
        locoType: locoType,
        loco: loco,
        route: route,
        positionInfo: positionInfo,
      );

  static bool _isFieldMeaningful(String field) {
    if (field.isEmpty) return false;
    final cleaned = field.replaceAll('<NUL>', '').trim();
    if (cleaned.isEmpty) return false;
    if (cleaned.runes
        .every((r) => r == '*'.runes.first || r == ' '.runes.first)) {
      return false;
    }
    return true;
  }

  /// A record is "time-only" when every informative field is invalid;
  /// such records never enter the merge cache and are always hidden.
  bool get isTimeOnly {
    final hasTrainNumber =
        _isFieldMeaningful(fullTrainNumber) && !fullTrainNumber.contains('-----');
    final hasDirection = direction == 1 || direction == 3;
    final hasLocoInfo = _isFieldMeaningful(locoType) || _isFieldMeaningful(loco);
    final hasRoute = _isFieldMeaningful(route);
    final hasPosition = _isFieldMeaningful(position);
    final hasSpeed = _isFieldMeaningful(speed) && speed != 'NUL';
    final hasPositionInfo = _isFieldMeaningful(positionInfo);
    final hasTrainType = _isFieldMeaningful(trainType) && trainType != '未知';
    final hasLbjClass = _isFieldMeaningful(lbjClass) && lbjClass != 'NA';
    final hasTrain = _isFieldMeaningful(train) && !train.contains('-----');
    return !(hasTrainNumber ||
        hasDirection ||
        hasLocoInfo ||
        hasRoute ||
        hasPosition ||
        hasSpeed ||
        hasPositionInfo ||
        hasTrainType ||
        hasLbjClass ||
        hasTrain);
  }

  /// Normalized grouping key for the train number, or null when invalid.
  String? get trainKey {
    final value = train.trim();
    final valid =
        value.isNotEmpty && value != '<NUL>' && !value.contains('-----');
    return valid ? value : null;
  }

  /// Normalized grouping key for the locomotive number, or null when invalid.
  String? get locoKey {
    final value = loco.trim();
    final valid = value.isNotEmpty && value != '<NUL>';
    return valid ? value : null;
  }

  /// Derived columns persisted on train_records for SQL-side filtering.
  Map<String, dynamic> derivedColumns() {
    return {
      'isTimeOnly': isTimeOnly ? 1 : 0,
      'trainKey': trainKey,
      'locoKey': locoKey,
    };
  }

  /// Lightweight JSON for isolate transfer / caching — skips the costly
  /// [searchText] computation, which is only needed for real DB writes.
  Map<String, dynamic> toTransferJson() {
    return {
      'uniqueId': uniqueId,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'receivedTimestamp': receivedTimestamp.millisecondsSinceEpoch,
      'train': train,
      'direction': direction,
      'speed': speed,
      'position': position,
      'time': time,
      'loco': loco,
      'locoType': locoType,
      'lbjClass': lbjClass,
      'route': route,
      'positionInfo': positionInfo,
      'rssi': rssi,
    };
  }

  Map<String, dynamic> toDatabaseJson() {
    return {
      ...toTransferJson(),
      'searchText': searchText,
    };
  }

  factory TrainRecord.fromDatabaseJson(Map<String, dynamic> json) {
    return TrainRecord(
      uniqueId: json['uniqueId']?.toString() ?? '',
      timestamp:
          DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int? ?? 0),
      receivedTimestamp: DateTime.fromMillisecondsSinceEpoch(
          json['receivedTimestamp'] as int? ?? 0),
      train: json['train']?.toString() ?? '',
      direction: json['direction'] as int? ?? 0,
      speed: json['speed']?.toString() ?? '',
      position: json['position']?.toString() ?? '',
      time: json['time']?.toString() ?? '',
      loco: json['loco']?.toString() ?? '',
      locoType: json['locoType']?.toString() ?? '',
      lbjClass: json['lbjClass']?.toString() ?? '',
      route: json['route']?.toString() ?? '',
      positionInfo: json['positionInfo']?.toString() ?? '',
      rssi: (json['rssi'] as num?)?.toDouble() ?? 0.0,
    );
  }

  String get directionText {
    switch (direction) {
      case 0:
        return '上行';
      case 1:
        return '下行';
      default:
        return '未知';
    }
  }

  String get locoTypeText {
    if (locoType.isEmpty) return '未知';
    return locoType;
  }

  String get trainType {
    final lbjClassValue = lbjClass.isEmpty ? "NA" : lbjClass;
    return TrainTypeUtil.getTrainType(lbjClassValue, train) ?? '未知';
  }

  String? get locoInfo {
    return LocoInfoUtil.getLocoInfoForRecord(locoType: locoType, loco: loco);
  }

  String get formattedLocoDisplay =>
      LocoTypeUtil.formatLocoDisplay(locoType, loco);

  String get fullTrainNumber =>
      TrainRecord.computeFullTrainNumber(lbjClass, train);

  String get lbjClassText {
    if (lbjClass.isEmpty) return '未知';
    return lbjClass;
  }

  double get speedValue {
    try {
      return double.parse(speed.replaceAll(RegExp(r'[^\d.]'), ''));
    } catch (e) {
      return 0.0;
    }
  }

  String get speedUnit {
    if (speed.contains('km/h')) return 'km/h';
    if (speed.contains('m/s')) return 'm/s';
    return '';
  }

  String get formattedTime {
    return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';
  }

  String get formattedDate {
    return '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')}';
  }

  String get relativeTime {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inMinutes < 1) {
      return '刚刚';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}分钟前';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}小时前';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}天前';
    } else {
      return formattedDate;
    }
  }

  String get rssiDescription {
    if (rssi > -50) return '强';
    if (rssi > -70) return '中';
    if (rssi > -90) return '弱';
    return '无信号';
  }

  Color get rssiColor {
    if (rssi > -50) return Colors.green;
    if (rssi > -70) return Colors.orange;
    if (rssi > -90) return Colors.red;
    return Colors.grey;
  }

  Map<String, dynamic> toMap() {
    return {
      'uniqueId': uniqueId,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'receivedTimestamp': receivedTimestamp.millisecondsSinceEpoch,
      'train': train,
      'direction': direction,
      'speed': speed,
      'position': position,
      'time': time,
      'loco': loco,
      'locoType': locoType,
      'lbjClass': lbjClass,
      'route': route,
      'positionInfo': positionInfo,
      'rssi': rssi,
    };
  }

  Map<String, double> getCoordinates() {
    final parts = position.split(',');
    if (parts.length >= 2) {
      try {
        final lat = double.parse(parts[0].trim());
        final lng = double.parse(parts[1].trim());
        return {'lat': lat, 'lng': lng};
      } catch (e) {
        return {'lat': 0.0, 'lng': 0.0};
      }
    }
    return {'lat': 0.0, 'lng': 0.0};
  }

  TrainRecord copyWith({
    String? uniqueId,
    DateTime? timestamp,
    DateTime? receivedTimestamp,
    String? train,
    int? direction,
    String? speed,
    String? position,
    String? time,
    String? loco,
    String? locoType,
    String? lbjClass,
    String? route,
    String? positionInfo,
    double? rssi,
  }) {
    return TrainRecord(
      uniqueId: uniqueId ?? this.uniqueId,
      timestamp: timestamp ?? this.timestamp,
      receivedTimestamp: receivedTimestamp ?? this.receivedTimestamp,
      train: train ?? this.train,
      direction: direction ?? this.direction,
      speed: speed ?? this.speed,
      position: position ?? this.position,
      time: time ?? this.time,
      loco: loco ?? this.loco,
      locoType: locoType ?? this.locoType,
      lbjClass: lbjClass ?? this.lbjClass,
      route: route ?? this.route,
      positionInfo: positionInfo ?? this.positionInfo,
      rssi: rssi ?? this.rssi,
    );
  }

  @override
  String toString() {
    return 'TrainRecord(uniqueId: $uniqueId, train: $train, direction: $direction, speed: $speed, position: $position)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TrainRecord && other.uniqueId == uniqueId;
  }

  @override
  int get hashCode => uniqueId.hashCode;
}
