import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Windows 系统托盘：关闭窗口时最小化到托盘，而非退出程序。
class WindowsTrayService with WindowListener, TrayListener {
  WindowsTrayService._();

  static final WindowsTrayService instance = WindowsTrayService._();

  bool _initialized = false;

  static bool get isSupported => Platform.isWindows;

  Future<void> initialize() async {
    if (!isSupported || _initialized) return;

    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    await trayManager.setIcon('assets/tray_icon.ico');
    await trayManager.setToolTip('LBJ Console');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: '显示主窗口'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: '退出'),
        ],
      ),
    );
    trayManager.addListener(this);

    _initialized = true;
  }

  Future<void> showMainWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> exitApp() async {
    await trayManager.destroy();
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
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
        exitApp();
    }
  }
}
