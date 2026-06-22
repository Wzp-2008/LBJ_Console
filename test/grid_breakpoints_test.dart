import 'package:flutter_test/flutter_test.dart';

import 'package:lbjconsole/screens/history_screen.dart';

void main() {
  group('HistoryScreen.crossAxisCountForWidth', () {
    test('returns 1 column on narrow screens', () {
      expect(HistoryScreenState.crossAxisCountForWidth(0), 1);
      expect(HistoryScreenState.crossAxisCountForWidth(360), 1);
      expect(HistoryScreenState.crossAxisCountForWidth(499), 1);
    });

    test('returns 2 columns at the 500px breakpoint', () {
      expect(HistoryScreenState.crossAxisCountForWidth(500), 2);
      expect(HistoryScreenState.crossAxisCountForWidth(799), 2);
    });

    test('returns 3 columns at the 800px breakpoint', () {
      expect(HistoryScreenState.crossAxisCountForWidth(800), 3);
      expect(HistoryScreenState.crossAxisCountForWidth(1100), 3);
      expect(HistoryScreenState.crossAxisCountForWidth(1199), 3);
    });

    test('returns 4 columns at the 1200px breakpoint', () {
      expect(HistoryScreenState.crossAxisCountForWidth(1200), 4);
      expect(HistoryScreenState.crossAxisCountForWidth(1500), 4);
      expect(HistoryScreenState.crossAxisCountForWidth(1599), 4);
    });

    test('returns 5 columns at the 1600px breakpoint and caps there', () {
      expect(HistoryScreenState.crossAxisCountForWidth(1600), 5);
      expect(HistoryScreenState.crossAxisCountForWidth(2560), 5);
      expect(HistoryScreenState.crossAxisCountForWidth(99999.0), 5);
    });

    test('never returns fewer than 1 or more than 5', () {
      for (final w in [0.0, 100.0, 499.0, 500.0, 799.0, 800.0, 1199.0, 1200.0, 1599.0, 1600.0, 4000.0]) {
        final c = HistoryScreenState.crossAxisCountForWidth(w);
        expect(c, greaterThanOrEqualTo(1));
        expect(c, lessThanOrEqualTo(5));
      }
    });
  });
}
