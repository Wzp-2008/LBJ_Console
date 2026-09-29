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
  static Future<void>? _initializing;
  static StreamSubscription<bool>? _connectionSubscription;
  static StreamSubscription<Map<String, dynamic>?>? _statusRequestSubscription;

  static Future<void> initialize() async {
    if (!Platform.isAndroid || _isInitialized) return;
    final pending = _initializing ??= _configure();
    try {
      await pending;
    } finally {
      _initializing = null;
    }
  }

  static Future<void> _configure() async {
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
        autoStart: false,
        autoStartOnBoot: false,
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

    _connectionSubscription ??= BLEService().connectionStream.listen(
      (_) => _publishStatus(),
    );
    _statusRequestSubscription ??= service
        .on('requestStatus')
        .listen((_) => _publishStatus());
    _isInitialized = true;
  }

  static void _publishStatus() {
    final ble = BLEService();
    FlutterBackgroundService().invoke('updateStatus', {
      'body': ble.isConnected ? '蓝牙已连接 - ${ble.deviceStatus}' : '蓝牙未连接，等待重连',
    });
  }

  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();
    // This isolate only keeps Android's foreground service alive. The main
    // isolate owns BLE, its database and reconnect policy; a second singleton
    // here cannot share that state and would contend for the same adapter.
    StreamSubscription<Map<String, dynamic>?>? statusSubscription;
    StreamSubscription<Map<String, dynamic>?>? stopSubscription;
    String? lastBody;
    var stopped = false;
    statusSubscription = service.on('updateStatus').listen((event) async {
      final body = event?['body'] as String?;
      if (stopped || body == null || body == lastBody) return;
      lastBody = body;
      try {
        await FlutterLocalNotificationsPlugin().show(
          id: _notificationId,
          title: 'LBJ Console',
          body: body,
          notificationDetails: _backgroundNotificationDetails(),
        );
      } catch (error, stack) {
        developer.log(
          '后台服务通知更新失败：$error',
          name: 'BackgroundService',
          stackTrace: stack,
        );
      }
    });
    stopSubscription = service.on('stopService').listen((_) async {
      stopped = true;
      await statusSubscription?.cancel();
      await stopSubscription?.cancel();
      await service.stopSelf();
    });
    service.invoke('requestStatus');
  }

  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    return true;
  }

  static Future<void> startService() async {
    if (!Platform.isAndroid || !BLEService().isConnected) return;
    await NotificationService.instance.requestPermission();
    await initialize();
    final service = FlutterBackgroundService();

    if (!await service.isRunning()) {
      await service.startService();
    }
    _publishStatus();
  }

  static Future<void> stopService() async {
    if (!Platform.isAndroid) return;
    final service = FlutterBackgroundService();
    service.invoke('stopService');
  }

  static Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    final service = FlutterBackgroundService();
    return await service.isRunning();
  }
}
