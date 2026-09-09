import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:lbjconsole/screens/main_screen.dart';
import 'package:lbjconsole/util/train_type_util.dart';
import 'package:lbjconsole/util/loco_info_util.dart';
import 'package:lbjconsole/services/loco_type_service.dart';
import 'package:lbjconsole/services/sqflite_initializer.dart';
import 'package:lbjconsole/services/windows_tray_service.dart';
import 'package:lbjconsole/services/app_update_service.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  await AppUpdateService.cleanupFromArguments(args);

  await initializeSqflite();

  await _initializeNotifications();

  // await BackgroundService.initialize();

  await Future.wait([
    TrainTypeUtil.initialize(),
    LocoInfoUtil.initialize(),
    LocoTypeService().initialize(),
  ]);

  if (Platform.isWindows) {
    await WindowsTrayService.instance.initialize();
  }

  runApp(const LBJReceiverApp());
}

Future<void> _initializeNotifications() async {
  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    windows: WindowsInitializationSettings(
      appName: "LBJReceiver",
      appUserModelId: "LBJReceiver",
      guid: "194022DA-0502-4B90-8D31-14B3ECE27391",
    ),
  );

  await flutterLocalNotificationsPlugin.initialize(
    settings: initializationSettings,
  );
}

class LBJReceiverApp extends StatelessWidget {
  const LBJReceiverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LBJ Console',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.dark,
      home: const MainScreen(),
    );
  }
}
