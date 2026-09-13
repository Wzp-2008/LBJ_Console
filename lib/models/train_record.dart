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
    required int direction,
    required this.speed,
    required this.position,
    required this.time,
    required this.loco,
    required this.locoType,
    required this.lbjClass,
    required this.route,
    required this.positionInfo,
    required this.rssi,
  }) : direction = normalizeDirection(direction);

  /// Device data uses 0 for unknown, 1 for down and 3 for up. Keep this
  /// conversion at the model boundary so cards, summaries and notifications
  /// never need to repeat the wire-format rule.
  static int normalizeDirection(int value) => switch (value) {
    1 => 1,
    3 => 3,
    _ => 0,
  };

  static String _stringValue(Object? value) => value?.toString() ?? '';

  static int _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '') ?? 0;
  }

  static double _doubleValue(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().trim() ?? '') ?? 0.0;
  }

  factory TrainRecord.fromJson(Map<String, dynamic> json) {
    return TrainRecord(
      uniqueId: _stringValue(json['uniqueId'] ?? json['unique_id']).trim(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        _intValue(json['timestamp']),
      ),
      receivedTimestamp: DateTime.fromMillisecondsSinceEpoch(
        _intValue(json['receivedTimestamp'] ?? json['received_timestamp']),
      ),
      train: _stringValue(json['train']),
      direction: _intValue(json['direction'] ?? json['dir']),
      speed: _stringValue(json['speed']),
      position: _stringValue(json['position'] ?? json['pos']),
      time: _stringValue(json['time']),
      loco: _stringValue(json['loco']),
      locoType: _stringValue(json['locoType'] ?? json['loco_type']),
      lbjClass: _stringValue(json['lbjClass'] ?? json['lbj_class']),
      route: _stringValue(json['route']),
      positionInfo: _stringValue(json['positionInfo'] ?? json['position_info']),
      rssi: _doubleValue(json['rssi']),
    );
  }

  static bool _isMeaningfulSearchToken(String value) {
    if (value.isEmpty || value == '<NUL>' || value == 'NUL') return false;
    final cleaned = value.replaceAll('<NUL>', '').trim();
    if (cleaned.isEmpty || cleaned.contains('-----')) return false;
    if (cleaned.runes.every(
      (r) => r == '*'.runes.first || r == ' '.runes.first,
    )) {
      return false;
    }
    return true;
  }

  static String? _normalizeSearchToken(String value) {
    if (!_isMeaningfulSearchToken(value)) return null;
    return value
        .replaceAll('<NUL>', '')
        .replaceAll('-', '')
        .trim()
        .toLowerCase();
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

  String get searchText => buildSearchText(
    lbjClass: lbjClass,
    train: train,
    locoType: locoType,
    loco: loco,
    route: route,
    positionInfo: positionInfo,
  );

  static bool _isFieldMeaningful(String field) => isValidKeyValue(field);

  /// A record is "time-only" when every informative field is invalid;
  /// such records never enter the merge cache and are always hidden.
  bool get isTimeOnly {
    final hasTrainNumber =
        _isFieldMeaningful(fullTrainNumber) &&
        !fullTrainNumber.contains('-----');
    final hasDirection = hasDirectionValue;
    final hasLocoInfo =
        _isFieldMeaningful(locoType) || _isFieldMeaningful(loco);
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
  String? get trainKey => isValidKeyValue(train) ? train.trim() : null;

  /// Normalized grouping key for the locomotive number, or null when invalid.
  String? get locoKey => isValidKeyValue(loco) ? loco.trim() : null;

  /// Whether a raw field value is clean enough to be used as a merge grouping
  /// key. Mirrors [MergeService]'s "good value" rule: rejects empty, `<NUL>`,
  /// `NA`, `NUL`, the per-character corruption markers `*` `(` `)`, and pure
  /// dash/dot/placeholder runs, by requiring at least one alphanumeric or CJK
  /// rune and none of those corruption markers. This keeps garbled values
  /// like `(9(99`, `((U1-`, `24800(74`, `85**` from becoming grouping keys —
  /// such records fall through to "ungroupable" and are hidden when the
  /// hide-ungroupable option is on.
  static bool isValidKeyValue(String? value) {
    if (value == null) return false;
    final v = value.replaceAll('<NUL>', '').trim();
    if (v.isEmpty) return false;
    final upper = v.toUpperCase();
    if (upper == 'NA' || upper == 'NUL') return false;
    if (v.contains('*') || v.contains('(') || v.contains(')')) return false;
    return v.runes.any(_isContentRune);
  }

  static bool _isContentRune(int r) {
    if (r >= 0x30 && r <= 0x39) return true; // 0-9
    if (r >= 0x41 && r <= 0x5A) return true; // A-Z
    if (r >= 0x61 && r <= 0x7A) return true; // a-z
    if (r >= 0x4E00 && r <= 0x9FFF) return true; // CJK Unified Ideographs
    if (r >= 0x3400 && r <= 0x4DBF) return true; // CJK Extension A
    return false;
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
    return {...toTransferJson(), 'searchText': searchText};
  }

  factory TrainRecord.fromDatabaseJson(Map<String, dynamic> json) {
    return TrainRecord(
      uniqueId: json['uniqueId']?.toString().trim() ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        _intValue(json['timestamp']),
      ),
      receivedTimestamp: DateTime.fromMillisecondsSinceEpoch(
        _intValue(json['receivedTimestamp']),
      ),
      train: json['train']?.toString() ?? '',
      direction: _intValue(json['direction']),
      speed: json['speed']?.toString() ?? '',
      position: json['position']?.toString() ?? '',
      time: json['time']?.toString() ?? '',
      loco: json['loco']?.toString() ?? '',
      locoType: json['locoType']?.toString() ?? '',
      lbjClass: json['lbjClass']?.toString() ?? '',
      route: json['route']?.toString() ?? '',
      positionInfo: json['positionInfo']?.toString() ?? '',
      rssi: _doubleValue(json['rssi']),
    );
  }

  bool get hasDirectionValue => direction == 1 || direction == 3;

  String? get directionBadge => switch (direction) {
    1 => '下',
    3 => '上',
    _ => null,
  };

  String get directionText {
    switch (direction) {
      case 1:
        return '下行';
      case 3:
        return '上行';
      default:
        return '未知';
    }
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
