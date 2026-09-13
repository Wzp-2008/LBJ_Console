import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Windows 系统托盘：关闭窗口时最小化到托盘，而非退出程序。
class WindowsTrayService with WindowListener, TrayListener {
  WindowsTrayService._();

  static final WindowsTrayService instance = WindowsTrayService._();

  bool _initialized = false;
  bool _criticalOperationActive = false;

  static bool get isSupported => Platform.isWindows;

  Future<void> initialize() async {
    if (!isSupported || _initialized) return;

    await windowManager.ensureInitialized();
    try {
      final executableDirectory = File(Platform.resolvedExecutable).parent.path;
      final packagedIcon = p.join(
        executableDirectory,
        'data',
        'flutter_assets',
        'assets',
        'tray_icon.ico',
      );
      final developmentIcon = p.join(
        Directory.current.path,
        'assets',
        'tray_icon.ico',
      );
      final iconPath = await File(packagedIcon).exists()
          ? packagedIcon
          : developmentIcon;
      if (!await File(iconPath).exists()) {
        throw StateError('找不到系统托盘图标：$iconPath');
      }

      await trayManager.setIcon(iconPath);
      await trayManager.setToolTip('LBJ Console');
      await _updateContextMenu();
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initialized = true;
    } catch (_) {
      await windowManager.setPreventClose(false);
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      rethrow;
    }
  }

  /// Prevents the app from being hidden or terminated while an operation is
  /// in the middle of writing device flash.
  Future<void> setCriticalOperationActive(bool active) async {
    _criticalOperationActive = active;
    if (_initialized) await _updateContextMenu();
  }

  Future<void> _updateContextMenu() {
    return trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: '显示主窗口'),
          MenuItem.separator(),
          MenuItem(
            key: 'exit',
            label: _criticalOperationActive ? '刷写进行中，暂不可退出' : '退出',
            disabled: _criticalOperationActive,
          ),
        ],
      ),
    );
  }

  Future<void> showMainWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> exitApp() async {
    if (_criticalOperationActive) return;
    // Remove the tray icon first so the user gets immediate feedback, then
    // terminate the process. The native message loop
    // (windows/runner/main.cpp) runs with SetQuitOnClose(false) for tray
    // mode, so windowManager.destroy() would destroy the window WITHOUT
    // posting WM_QUIT — leaving the process lingering ~5-10s (and an open
    // window "Not Responding" during Flutter teardown). exit(0) ends the
    // process promptly; Windows tears down the window. SQLite WAL is
    // crash-safe on abrupt exit, so there is no database corruption.
    await trayManager.destroy();
    exit(0);
  }

  @override
  void onWindowClose() {
    if (_criticalOperationActive) {
      unawaited(showMainWindow());
      return;
    }
    windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    showMainWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showMainWindow();
      case 'exit':
        if (!_criticalOperationActive) unawaited(exitApp());
    }
  }
}
