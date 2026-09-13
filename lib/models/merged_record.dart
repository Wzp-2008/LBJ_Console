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
}
