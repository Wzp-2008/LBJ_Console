import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lbjconsole/screens/main_screen.dart';
import 'package:lbjconsole/util/train_type_util.dart';
import 'package:lbjconsole/util/loco_info_util.dart';
import 'package:lbjconsole/util/loco_type_util.dart';
import 'package:lbjconsole/services/sqflite_initializer.dart';
import 'package:lbjconsole/services/windows_tray_service.dart';
import 'package:lbjconsole/services/app_update_service.dart';
import 'package:lbjconsole/themes/app_theme.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  await AppUpdateService.cleanupFromArguments(args);

  await initializeSqflite();

  await Future.wait([
    TrainTypeUtil.initialize(),
    LocoInfoUtil.initialize(),
    LocoTypeUtil().initialize(),
  ]);

  if (Platform.isWindows) {
    try {
      await WindowsTrayService.instance.initialize();
    } catch (_) {
      // A missing tray icon must not prevent the main window from starting.
    }
  }

  runApp(const LBJReceiverApp());
}

class LBJReceiverApp extends StatelessWidget {
  const LBJReceiverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LBJ Console',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: const MainScreen(),
    );
  }
}
