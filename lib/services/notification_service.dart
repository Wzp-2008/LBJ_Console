import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:lbjconsole/models/train_record.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  static const String channelId = 'lbj_messages';
  static const String channelName = 'LBJ Messages';
  static const String channelDescription = 'Receive LBJ messages';

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  int _notificationId = 1000;

  /// User intent: whether the user wants notifications (settings toggle).
  bool _notificationsEnabled = true;
  /// System capability: whether the OS currently allows this app to post
  /// notifications. On Android 13+ this reflects the POST_NOTIFICATIONS
  /// runtime permission. Cached here and refreshed on init / request.
  bool _permissionGranted = false;

  final StreamController<bool> _settingsController =
      StreamController<bool>.broadcast();
  Stream<bool> get settingsStream => _settingsController.stream;

  Future<void> initialize() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings =
        InitializationSettings(
            android: initializationSettingsAndroid,
            windows: WindowsInitializationSettings(appName: "LBJReceiver", appUserModelId: "LBJReceiver", guid: "194022DA-0502-4B90-8D31-14B3ECE27391")
    );

    await _notificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (details) {},
    );

    await _createNotificationChannel();

    // Reflect the actual system permission (Android 13+ may have it denied).
    _permissionGranted = await _systemNotificationsEnabled();
    _settingsController.add(_permissionGranted);
  }

  Future<void> _createNotificationChannel() async {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      channelId,
      channelName,
      description: channelDescription,
      importance: Importance.high,
      enableVibration: true,
      playSound: true,
    );

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  /// Requests the Android POST_NOTIFICATIONS runtime permission (Android 13+).
  /// Required for train notifications to actually show and for the background
  /// foreground-service notification to display. Safe to call repeatedly —
  /// the system only shows the prompt the first time; later calls return the
  /// stored decision. Returns whether notifications may be shown.
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) {
      _permissionGranted = true;
      _settingsController.add(_permissionGranted);
      return true;
    }
    final android = _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) {
      _permissionGranted = false;
      _settingsController.add(_permissionGranted);
      return false;
    }
    final granted = await android.requestNotificationsPermission() ?? false;
    _permissionGranted = granted;
    _settingsController.add(_permissionGranted);
    return granted;
  }

  /// Whether the system currently allows this app to post notifications.
  Future<bool> _systemNotificationsEnabled() async {
    if (!Platform.isAndroid) return true;
    final android = _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    return await android?.areNotificationsEnabled() ?? false;
  }

  Future<void> showTrainNotification(TrainRecord record) async {
    if (!_notificationsEnabled) return;
    if (!_permissionGranted) return;

    if (!_isValidValue(record.train) ||
        !_isValidValue(record.route) ||
        !_isValidValue(record.directionText)) {
      return;
    }

    const String title = '列车信息';
    final String body = _buildNotificationContent(record);

    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      ticker: 'ticker',
      styleInformation: BigTextStyleInformation(body),
    );

    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await _notificationsPlugin.show(
      id: _notificationId++,
      title: title,
      body: body,
      notificationDetails: platformChannelSpecifics,
      payload: 'train_${record.train}',
    );
  }

  String _buildNotificationContent(TrainRecord record) {
    final buffer = StringBuffer();

    buffer.write(record.fullTrainNumber);
    if (_isValidValue(record.route)) {
      buffer.write(' ${record.route}');
    }
    if (_isValidValue(record.directionText)) {
      buffer.write(' ${record.directionText}');
    }
    if (_isValidValue(record.positionInfo)) {
      buffer.write(' ${record.positionInfo}');
    }
    buffer.writeln();
    if (_isValidValue(record.loco) || _isValidValue(record.locoType)) {
      buffer.write(record.formattedLocoDisplay);
    }

    if (_isValidValue(record.speed)) {
      buffer.write(' ${record.speed}km/h');
    }

    return buffer.toString().trim();
  }

  bool _isValidValue(String? value) {
    if (value == null || value.isEmpty) return false;
    final trimmed = value.trim();
    return trimmed.isNotEmpty &&
        trimmed != 'NUL' &&
        trimmed != 'NA' &&
        trimmed != '*';
  }

  Future<void> enableNotifications(bool enable) async {
    _notificationsEnabled = enable;
    _settingsController.add(_notificationsEnabled);
  }

  Future<bool> isNotificationEnabled() async {
    return _notificationsEnabled;
  }

  Future<void> cancelAllNotifications() async {
    await _notificationsPlugin.cancelAll();
  }

  void dispose() {
    _settingsController.close();
  }
}
