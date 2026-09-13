import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lbjconsole/themes/app_theme.dart';

void main() {
  test(
    'navigation bar keeps the selected text white and indicator readable',
    () {
      final theme = AppTheme.darkTheme.navigationBarTheme;
      final selected = {WidgetState.selected};
      final unselected = <WidgetState>{};

      expect(theme.backgroundColor, AppTheme.secondaryBlack);
      expect(theme.indicatorColor, AppTheme.navigationIndicator);
      expect(theme.indicatorColor, isNot(Colors.white));

      final selectedLabel = theme.labelTextStyle!.resolve(selected)!;
      final unselectedLabel = theme.labelTextStyle!.resolve(unselected)!;
      expect(selectedLabel.color, Colors.white);
      expect(unselectedLabel.color, Colors.white70);

      final selectedIcon = theme.iconTheme!.resolve(selected)!;
      final unselectedIcon = theme.iconTheme!.resolve(unselected)!;
      expect(selectedIcon.color, Colors.white);
      expect(unselectedIcon.color, Colors.white70);
    },
  );
}
