import 'package:flutter/services.dart';
import 'package:lbjconsole/util/csv_parser.dart';

class TrainTypeUtil {
  static final List<_TrainTypePattern> _patterns = [];
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      final csvData = await rootBundle.loadString(
        'assets/train_number_info.csv',
      );
      final lines = csvData.split('\n');

      for (final line in lines) {
        if (line.trim().isEmpty) continue;

        final fields = parseCsvLine(line);
        if (fields.length >= 2) {
          try {
            _patterns.add(_TrainTypePattern(RegExp(fields[0]), fields[1]));
          } catch (e) {
            // Ignore malformed asset rows and keep loading valid rows.
          }
        }
      }
      _initialized = true;
    } catch (e) {
      _initialized = true;
    }
  }

  static String? getTrainType(String lbjClass, String train) {
    if (!_initialized) {
      return null;
    }

    final lbjClassTrimmed = lbjClass.trim();
    final trainTrimmed = train.trim();

    if (trainTrimmed.isEmpty || trainTrimmed == "<NUL>") {
      return null;
    }

    final actualTrain = lbjClassTrimmed == "NA"
        ? trainTrimmed
        : lbjClassTrimmed + trainTrimmed;

    for (final pattern in _patterns) {
      if (pattern.regex.hasMatch(actualTrain)) {
        return pattern.type;
      }
    }

    return null;
  }
}

class _TrainTypePattern {
  final RegExp regex;
  final String type;

  _TrainTypePattern(this.regex, this.type);
}
