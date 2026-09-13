import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:lbjconsole/services/ble_service.dart';
import 'package:lbjconsole/services/notification_service.dart';

const String _notificationChannelId = 'lbj_console_channel';
const String _notificationChannelName = 'LBJ Console 后台服务';
const String _notificationChannelDescription = '保持蓝牙连接稳定';
const int _notificationId = 114514;
const AndroidNotificationChannel _backgroundNotificationChannel =
    AndroidNotificationChannel(
      _notificationChannelId,
      _notificationChannelName,
      description: _notificationChannelDescription,
      importance: Importance.low,
      enableLights: false,
      enableVibration: false,
      playSound: false,
    );

NotificationDetails _backgroundNotificationDetails() {
  return const NotificationDetails(
    android: AndroidNotificationDetails(
      _notificationChannelId,
      _notificationChannelName,
      channelDescription: _notificationChannelDescription,
      icon: '@mipmap/ic_launcher',
      ongoing: true,
      autoCancel: false,
      importance: Importance.low,
      priority: Priority.low,
      enableLights: false,
      enableVibration: false,
      playSound: false,
      onlyAlertOnce: true,
      setAsGroupSummary: false,
      groupKey: 'lbj_console_group',
      visibility: NotificationVisibility.public,
      category: AndroidNotificationCategory.service,
    ),
  );
}

@pragma('vm:entry-point')
class BackgroundService {
  static bool _isInitialized = false;

  static Future<void> initialize() async {
    if (_isInitialized) return;

    final service = FlutterBackgroundService();

    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    if (Platform.isAndroid) {
      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(_backgroundNotificationChannel);
    }

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: true,
        isForegroundMode: true,
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: 'LBJ Console',
        initialNotificationContent: '蓝牙连接监控中',
        foregroundServiceNotificationId: _notificationId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );

    _isInitialized = true;
  }

  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    service.on('stopService').listen((event) {
      service.stopSelf();
    });

    BLEService().initialize();

    if (service is AndroidServiceInstance) {
      await Future.delayed(const Duration(seconds: 1));
      if (await service.isForegroundService()) {
        final flutterLocalNotificationsPlugin =
            FlutterLocalNotificationsPlugin();

        try {
          await flutterLocalNotificationsPlugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.createNotificationChannel(_backgroundNotificationChannel);

          await flutterLocalNotificationsPlugin.show(
            id: _notificationId,
            title: 'LBJ Console',
            body: '蓝牙连接监控中',
            notificationDetails: _backgroundNotificationDetails(),
          );
        } catch (e, stack) {
          developer.log(
            '后台服务通知初始化失败：$e',
            name: 'BackgroundService',
            stackTrace: stack,
          );
        }
      }
    }

    Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (service is AndroidServiceInstance) {
        if (await service.isForegroundService()) {
          try {
            final bleService = BLEService();
            final isConnected = bleService.isConnected;
            final deviceStatus = bleService.deviceStatus;

            final flutterLocalNotificationsPlugin =
                FlutterLocalNotificationsPlugin();
            await flutterLocalNotificationsPlugin.show(
              id: _notificationId,
              title: 'LBJ Console',
              body: isConnected ? '蓝牙已连接 - $deviceStatus' : '蓝牙未连接 - 自动重连中',
              notificationDetails: _backgroundNotificationDetails(),
            );
          } catch (e, stack) {
            developer.log(
              '后台服务通知更新失败：$e',
              name: 'BackgroundService',
              stackTrace: stack,
            );
          }
        }
      }
    });
  }

  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    return true;
  }

  static Future<void> startService() async {
    if (Platform.isWindows) return;
    await initialize();
    final service = FlutterBackgroundService();

    if (Platform.isAndroid) {
      // The foreground service needs a persistent notification; on Android
      // 13+ that requires the POST_NOTIFICATIONS runtime permission, so
      // request it before starting (covers both the settings toggle and the
      // auto-start path in MainScreen).
      await NotificationService.instance.requestPermission();
      final isRunning = await service.isRunning();
      if (!isRunning) {
        service.startService();
      }
    } else if (Platform.isIOS) {
      service.startService();
    }
  }

  static Future<void> stopService() async {
    if (Platform.isWindows) return;
    final service = FlutterBackgroundService();
    service.invoke('stopService');
  }

  static Future<bool> isRunning() async {
    if (Platform.isWindows) return false;
    final service = FlutterBackgroundService();
    return await service.isRunning();
  }
}
