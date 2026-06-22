import 'package:lbjconsole/models/train_record.dart';

class MergedTrainRecord {
  final String groupKey;
  final TrainRecord latestRecord;
  final TrainRecord summaryRecord;
  final List<String> memberUniqueIds;
  List<TrainRecord>? _detailRecords;

  MergedTrainRecord({
    required this.groupKey,
    required this.latestRecord,
    required this.summaryRecord,
    required this.memberUniqueIds,
    List<TrainRecord>? detailRecords,
  }) : _detailRecords = detailRecords;

  int get recordCount => memberUniqueIds.length;

  bool get hasLoadedDetails =>
      _detailRecords != null &&
      _detailRecords!.length >= memberUniqueIds.length;

  /// Collapsed card / lightweight access — latest only until expanded.
  List<TrainRecord> get records {
    if (hasLoadedDetails) return _detailRecords!;
    return [latestRecord];
  }

  void setDetailRecords(List<TrainRecord> loaded) {
    _detailRecords = loaded;
  }

  bool containsRecordId(String uniqueId) => memberUniqueIds.contains(uniqueId);

  /// Resolve from in-memory page cache without hitting the database.
  List<TrainRecord> resolveFromCache(List<TrainRecord> cache) {
    if (hasLoadedDetails) return _detailRecords!;
    final fromCache =
        cache.where((r) => memberUniqueIds.contains(r.uniqueId)).toList();
    if (fromCache.length >= memberUniqueIds.length) {
      fromCache.sort(
        (a, b) => b.receivedTimestamp.compareTo(a.receivedTimestamp),
      );
      return fromCache;
    }
    return records;
  }
}

