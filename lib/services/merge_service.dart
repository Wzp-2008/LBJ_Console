import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:lbjconsole/models/train_record.dart';

/// Field aggregation for merged record groups. Grouping itself lives in
/// DisplayGroupCache (fixed rule: train OR loco key, 1 hour window).
class MergeService {
  /// Whether [value] carries real, displayable content.
  ///
  /// A value is "good" iff, after stripping `<NUL>` and trimming, it is
  /// non-empty, not the `NA`/`NUL` sentinel, and contains at least one
  /// alphanumeric or CJK rune. Testing for the *presence of real content*
  /// rejects every observed placeholder (`""`, `"<NUL>"`, `"-----"`,
  /// `"----.-"`, `"*****"`, `"NA"`, `"NUL"`, …) without enumerating them, so
  /// new dash/asterisk variants are rejected automatically. Real values
  /// (`"57908"`, `"K"`, `"京九线"`, `"30°18.1522′ 120°10.9625′"`, `"5"`,
  /// `"41010559"`) always contain an alphanumeric or CJK rune.
  static bool _isGoodValue(String? value) {
    if (value == null) return false;
    final v = value.replaceAll('<NUL>', '').trim();
    if (v.isEmpty) return false;
    final upper = v.toUpperCase();
    if (upper == 'NA' || upper == 'NUL') return false;
    return v.runes.any(_isContentRune);
  }

  /// Test accessor for [_isGoodValue].
  @visibleForTesting
  static bool isGoodValue(String? value) => _isGoodValue(value);

  static bool _isContentRune(int r) {
    if (r >= 0x30 && r <= 0x39) return true; // 0-9
    if (r >= 0x41 && r <= 0x5A) return true; // A-Z
    if (r >= 0x61 && r <= 0x7A) return true; // a-z
    if (r >= 0x4E00 && r <= 0x9FFF) return true; // CJK Unified Ideographs
    if (r >= 0x3400 && r <= 0x4DBF) return true; // CJK Extension A
    return false;
  }

  /// Newest-first scan: returns the first record's value that is "good";
  /// if no member has a good value, returns `''` (the display layer skips
  /// broken/empty values anyway, and persisting `''` is cleaner than a
  /// broken placeholder).
  static String _bestField(
    List<TrainRecord> records,
    String Function(TrainRecord) getter,
  ) {
    for (final record in records) {
      final value = getter(record).trim();
      if (_isGoodValue(value)) return value;
    }
    return '';
  }

  /// Picks the member that contributes `train` + `lbjClass` to the summary, so
  /// the two stay sourced from one record (no Frankenstein full train
  /// number).
  ///
  /// Preference order (newest-first within each tier):
  /// 1. A record with both a valid train AND a real (non-empty, non-NA)
  ///    lbjClass — i.e. a complete combined form like "D11".
  /// 2. A record with a valid train but no class (form like "11").
  /// 3. null — no member has a usable train.
  ///
  /// Tier 1 over tier 2 is what keeps the class prefix: a newer member with
  /// an empty lbjClass must not shadow an older member that carries the real
  /// class (otherwise "D11" degrades to "11").
  static TrainRecord? _recordWithBestFullTrain(List<TrainRecord> records) {
    TrainRecord? trainOnly;
    for (final record in records) {
      final train = record.train.trim();
      if (train.isEmpty ||
          train == '<NUL>' ||
          train.contains('-----') ||
          train.toUpperCase() == 'NA') {
        continue;
      }
      final cls = record.lbjClass.trim();
      final hasClass = cls.isNotEmpty && cls.toUpperCase() != 'NA';
      if (hasClass) {
        // Newest member with a complete class+train form.
        return record;
      }
      trainOnly ??= record;
    }
    return trainOnly;
  }

  /// Builds the aggregated summary shown on a merged card. [records] must be
  /// sorted newest first.
  ///
  /// Each field takes the newest "good" value across members (a live
  /// stream's most recent real observation, filling gaps from older
  /// members). `train` + `lbjClass` come from the same best-train record so
  /// the full train number is never a Frankenstein mix of two records.
  static TrainRecord buildSummaryRecord(List<TrainRecord> records) {
    if (records.isEmpty) {
      throw ArgumentError('buildSummaryRecord requires at least one record');
    }
    final latest = records.first;
    final bestTrainRecord = _recordWithBestFullTrain(records);
    return TrainRecord(
      uniqueId: latest.uniqueId,
      timestamp: latest.timestamp,
      receivedTimestamp: latest.receivedTimestamp,
      train: bestTrainRecord?.train ?? _bestField(records, (r) => r.train),
      direction: records
          .firstWhere((r) => r.direction == 0 || r.direction == 1,
              orElse: () => latest)
          .direction,
      speed: _bestField(records, (r) => r.speed),
      position: _bestField(records, (r) => r.position),
      time: _bestField(records, (r) => r.time),
      loco: _bestField(records, (r) => r.loco),
      locoType: _bestField(records, (r) => r.locoType),
      lbjClass:
          bestTrainRecord?.lbjClass ?? _bestField(records, (r) => r.lbjClass),
      route: _bestField(records, (r) => r.route),
      positionInfo: _bestField(records, (r) => r.positionInfo),
      rssi: latest.rssi,
    );
  }
}
