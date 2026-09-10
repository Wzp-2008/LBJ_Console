import 'package:lbjconsole/services/ble_diagnostics.dart';
import 'package:lbjconsole/services/ble_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter_blue_plus_windows/flutter_blue_plus_windows.dart';
import 'package:lbjconsole/screens/history_screen.dart';
import 'package:lbjconsole/screens/settings_screen.dart';
import 'package:lbjconsole/services/ble_service.dart';
import 'package:lbjconsole/services/database_service.dart';
import 'package:lbjconsole/services/notification_service.dart';
import 'package:lbjconsole/services/background_service.dart';
import 'package:lbjconsole/services/rtl_tcp_service.dart';
import 'package:lbjconsole/services/audio_input_service.dart';
import 'package:lbjconsole/themes/app_theme.dart';
import 'package:lbjconsole/widgets/audio_waterfall_widget.dart';
import 'package:lbjconsole/services/app_update_service.dart';
import 'package:lbjconsole/services/firmware_ota_service.dart';
import 'package:lbjconsole/services/classic_spp_service.dart';

class _ConnectionStatusWidget extends StatefulWidget {
  final BLEService bleService;
  final RtlTcpService rtlTcpService;
  final DateTime? lastReceivedTime;
  final DateTime? rtlTcpLastReceivedTime;
  final DateTime? audioLastReceivedTime;
  final InputSource inputSource;
  final bool rtlTcpConnected;

  const _ConnectionStatusWidget({
    required this.bleService,
    required this.rtlTcpService,
    required this.lastReceivedTime,
    required this.rtlTcpLastReceivedTime,
    required this.audioLastReceivedTime,
    required this.inputSource,
    required this.rtlTcpConnected,
  });

  @override
  State<_ConnectionStatusWidget> createState() =>
      _ConnectionStatusWidgetState();
}

class _ConnectionStatusWidgetState extends State<_ConnectionStatusWidget> {
  StreamSubscription? _connectionSubscription;
  String _deviceStatus = "未连接";
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    _connectionSubscription = widget.bleService.connectionStream.listen((
      connected,
    ) {
      if (mounted) {
        setState(() {
          _isConnected = connected;
          _deviceStatus = connected ? "已连接" : "未连接";
        });
      }
    });
    _isConnected = widget.bleService.isConnected;
    _deviceStatus = widget.bleService.deviceStatus;
  }

  @override
  void didUpdateWidget(covariant _ConnectionStatusWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inputSource != widget.inputSource ||
        oldWidget.rtlTcpConnected != widget.rtlTcpConnected) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isConnected;
    Color statusColor;
    String statusText;
    DateTime? displayTime;

    switch (widget.inputSource) {
      case InputSource.rtlTcp:
        isConnected = widget.rtlTcpConnected;
        statusColor = isConnected ? Colors.green : Colors.red;
        statusText = isConnected ? '已连接' : '未连接';
        displayTime = widget.rtlTcpLastReceivedTime;
        break;
      case InputSource.audioInput:
        isConnected = AudioInputService().isListening;
        statusColor = isConnected ? Colors.green : Colors.red;
        statusText = isConnected ? '监听中' : '已停止';
        displayTime = widget.audioLastReceivedTime;
        break;
      case InputSource.bluetooth:
        isConnected = _isConnected;
        statusColor = isConnected ? Colors.green : Colors.red;
        statusText = _deviceStatus;
        displayTime = widget.lastReceivedTime;
        break;
    }

    return Row(
      children: [
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (displayTime == null || !isConnected) ...[
              Text(
                statusText,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
            _LastReceivedTimeWidget(
              lastReceivedTime: displayTime,
              isConnected: isConnected,
            ),
          ],
        ),
        const SizedBox(width: 8),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
        ),
      ],
    );
  }
}

class _LastReceivedTimeWidget extends StatefulWidget {
  final DateTime? lastReceivedTime;
  final bool isConnected;

  const _LastReceivedTimeWidget({
    required this.lastReceivedTime,
    required this.isConnected,
  });

  @override
  State<_LastReceivedTimeWidget> createState() =>
      _LastReceivedTimeWidgetState();
}

class _LastReceivedTimeWidgetState extends State<_LastReceivedTimeWidget> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(_LastReceivedTimeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lastReceivedTime != widget.lastReceivedTime ||
        oldWidget.isConnected != widget.isConnected) {
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (widget.lastReceivedTime != null && widget.isConnected) {
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  String _formatTime() {
    if (widget.lastReceivedTime == null) return '';

    final now = DateTime.now();
    final difference = now.difference(widget.lastReceivedTime!);

    if (difference.inDays > 0) {
      return '${difference.inDays}天前';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}小时前';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}分钟前';
    } else {
      return '${difference.inSeconds}秒前';
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lastReceivedTime == null || !widget.isConnected) {
      return const SizedBox.shrink();
    }

    return Text(
      _formatTime(),
      style: const TextStyle(color: Colors.white70, fontSize: 12),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;

  late final BLEService _bleService;
  late final RtlTcpService _rtlTcpService;
  final NotificationService _notificationService = NotificationService.instance;
  final DatabaseService _databaseService = DatabaseService.instance;

  StreamSubscription? _connectionSubscription;
  StreamSubscription? _rtlTcpConnectionSubscription;
  StreamSubscription? _audioConnectionSubscription;
  StreamSubscription? _dataSubscription;
  StreamSubscription? _rtlTcpDataSubscription;
  StreamSubscription? _audioDataSubscription;
  StreamSubscription? _lastReceivedTimeSubscription;
  StreamSubscription? _rtlTcpLastReceivedTimeSubscription;
  StreamSubscription? _audioLastReceivedTimeSubscription;
  StreamSubscription? _settingsSubscription;
  DateTime? _lastReceivedTime;
  DateTime? _rtlTcpLastReceivedTime;
  DateTime? _audioLastReceivedTime;
  bool _isHistoryEditMode = false;

  InputSource _inputSource = InputSource.bluetooth;
  int _recordCount = 0;

  bool _rtlTcpConnected = false;
  bool _isConnected = false;
  final GlobalKey<HistoryScreenState> _historyScreenKey =
      GlobalKey<HistoryScreenState>();
  late final AppUpdateService _updateService;
  late final FirmwareOtaService _firmwareOtaService;
  bool _checkingUpdate = false;
  bool _checkingFirmwareUpdate = false;
  bool _brickRecoveryActive = false;
  StreamSubscription<String>? _firmwareVersionSubscription;
  String? _firmwareVersion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bleService = BLEService();
    _rtlTcpService = RtlTcpService();
    _updateService = AppUpdateService();
    _firmwareOtaService = FirmwareOtaService(bleService: _bleService);
    _bleService.initialize();
    _loadInputSettings();
    _initializeServices();
    _checkAndStartBackgroundService();
    _setupConnectionListener();
    _setupLastReceivedTimeListener();
    _setupSettingsListener();
    _loadRecordCount();
    _firmwareVersionSubscription = _bleService.firmwareVersionStream.listen((
      version,
    ) {
      if (!mounted) return;
      setState(() => _firmwareVersion = version);
      _checkFirmwareUpdate();
    });
    final knownFirmwareVersion = _bleService.firmwareVersion;
    if (knownFirmwareVersion != null) {
      _firmwareVersion = knownFirmwareVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkFirmwareUpdate();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdate(showErrors: false, automatic: true);
    });
  }

  Future<void> _checkFirmwareUpdate({bool showErrors = false}) async {
    if (_checkingFirmwareUpdate ||
        !_bleService.isConnected ||
        _bleService.isOtaActive)
      return;
    _checkingFirmwareUpdate = true;
    try {
      final update = await _firmwareOtaService.checkForUpdate();
      if (!mounted) return;
      if (update == null) {
        if (showErrors)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('当前固件已是最新版本，或分享站暂无匹配固件')),
          );
        return;
      }
      await _showFirmwareUpdateDialog(update);
    } catch (e, stack) {
      BleDiagnostics.log('Firmware check failed', e, stack);
      if (showErrors && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('检查固件更新失败：$e')));
      }
    } finally {
      _checkingFirmwareUpdate = false;
    }
  }

  Future<void> _changeBluetoothDeviceName(String name) async {
    await _bleService.setRemoteDeviceName(name);
  }

  Future<void> _showFirmwareUpdateDialog(FirmwareUpdateInfo update) async {
    if (!mounted) return;
    var downloading = false;
    var progress = 0.0;
    var otaState = '等待开始';
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) => PopScope(
            canPop: !downloading,
            child: AlertDialog(
              title: const Text('发现新固件'),
              content: downloading
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LinearProgressIndicator(value: progress),
                        const SizedBox(height: 12),
                        Text(
                          '$otaState ${(progress * 100).toStringAsFixed(0)}%',
                        ),
                      ],
                    )
                  : Text(
                      '当前固件：${_bleService.firmwareVersion ?? '未知'}\n'
                      '最新固件：${update.version}\n文件：${update.fileName}'
                      '${update.uploadTime == null ? '' : '\n上传时间：${update.uploadTime}'}',
                    ),
              actions: [
                if (!downloading)
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('暂不更新'),
                  ),
                if (!downloading)
                  FilledButton(
                    onPressed: () async {
                      setState(() {
                        downloading = true;
                        progress = 0;
                        otaState = '正在下载/升级';
                      });
                      try {
                        await _firmwareOtaService.installUpdate(
                          update,
                          onProgress: (value) {
                            if (context.mounted)
                              setState(() => progress = value);
                          },
                          onState: (state) {
                            if (context.mounted) {
                              setState(() {
                                final phase =
                                    state['state']?.toString() ?? otaState;
                                otaState = otaStateLabel(phase);
                                if (phase == 'starting' ||
                                    phase == 'reconnecting') {
                                  progress = 0;
                                }
                              });
                            }
                          },
                        );
                        if (context.mounted) {
                          setState(() => downloading = false);
                          Navigator.pop(dialogContext);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('固件升级成功，设备即将重启')),
                          );
                        }
                      } catch (e, stack) {
                        BleDiagnostics.log("Firmware install failed", e, stack);
                        if (context.mounted) {
                          setState(() => downloading = false);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '固件升级失败：$e\n日志：${BleDiagnostics.logPath}',
                              ),
                            ),
                          );
                        }
                      }
                    },
                    child: const Text('升级固件'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _startWirelessBrickRecovery() async {
    if (_brickRecoveryActive) return;
    if (_bleService.isOtaActive) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已有固件升级正在进行')));
      return;
    }

    _brickRecoveryActive = true;
    try {
      final device = await _findRescueSppDevice();
      if (!mounted || device == null) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已选择 ${device.displayName}，正在查询最新固件')),
      );
      final update = await _firmwareOtaService.findLatestFirmware();
      if (!mounted) return;
      if (update == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('分享站暂无匹配的最新固件')));
        return;
      }
      await _showRescueFirmwareDialog(update, device);
    } catch (error, stack) {
      BleDiagnostics.log('Wireless brick recovery failed', error, stack);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无线救砖失败：$error')));
      }
    } finally {
      _brickRecoveryActive = false;
    }
  }

  Future<ClassicBluetoothDevice?> _findRescueSppDevice() {
    if (!mounted) return Future.value();
    return showDialog<ClassicBluetoothDevice>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => const _RescueDevicePickerDialog(),
    );
  }

  Future<void> _showRescueFirmwareDialog(
    FirmwareUpdateInfo update,
    ClassicBluetoothDevice device,
  ) async {
    var installing = false;
    var progress = 0.0;
    var otaState = '等待开始';
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) => PopScope(
            canPop: !installing,
            child: AlertDialog(
              title: const Text('无线救砖升级'),
              content: installing
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LinearProgressIndicator(value: progress),
                        const SizedBox(height: 12),
                        Text(
                          '$otaState ${(progress * 100).toStringAsFixed(0)}%',
                        ),
                      ],
                    )
                  : Text(
                      '设备：${device.displayName}\n'
                      '运行模式：Updater SPP\n'
                      '最新固件：${update.version}\n'
                      '文件：${update.fileName}'
                      '${update.uploadTime == null ? '' : '\n上传时间：${update.uploadTime}'}\n\n'
                      '升级过程中请勿关闭程序或断开蓝牙。',
                    ),
              actions: [
                if (!installing)
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('取消'),
                  ),
                if (!installing)
                  FilledButton(
                    onPressed: () async {
                      setState(() {
                        installing = true;
                        progress = 0;
                        otaState = '准备升级';
                      });
                      try {
                        await _firmwareOtaService.installSppUpdate(
                          update,
                          connectSpp: () =>
                              ClassicSppService.connectOtaTransport(
                                device.address,
                              ),
                          onProgress: (value) {
                            if (context.mounted) {
                              setState(() => progress = value);
                            }
                          },
                          onState: (state) {
                            if (context.mounted) {
                              setState(() {
                                final phase =
                                    state['state']?.toString() ?? otaState;
                                otaState = otaStateLabel(phase);
                                if (phase == 'reconnecting') progress = 0;
                              });
                            }
                          },
                        );
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext);
                        }
                        if (mounted) {
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            const SnackBar(content: Text('无线救砖升级成功，设备即将重启')),
                          );
                        }
                      } catch (error, stack) {
                        BleDiagnostics.log(
                          'Wireless brick recovery install failed',
                          error,
                          stack,
                        );
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext);
                        }
                        if (mounted) {
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '无线救砖升级失败：$error\n日志：${BleDiagnostics.logPath}',
                              ),
                            ),
                          );
                        }
                      }
                    },
                    child: const Text('开始刷写'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _checkForUpdate({
    required bool showErrors,
    bool automatic = false,
  }) async {
    if (_checkingUpdate || !_updateService.isSupported) return;
    _checkingUpdate = true;
    try {
      final update = await _updateService.checkForUpdate();
      if (!mounted || update == null) return;
      await _showUpdateDialog(update, automatic: automatic);
    } catch (e) {
      if (showErrors && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('检查更新失败：$e')));
      }
    } finally {
      _checkingUpdate = false;
    }
  }

  Future<void> _showUpdateDialog(
    AppUpdateInfo update, {
    required bool automatic,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: !automatic,
      builder: (dialogContext) {
        var downloading = false;
        var progress = 0.0;
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('发现新版本'),
            content: downloading
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(value: progress),
                      const SizedBox(height: 12),
                      Text('正在下载 ${(progress * 100).toStringAsFixed(0)}%'),
                    ],
                  )
                : Text(
                    '当前版本：$appBuildHash\n最新版本：${update.hash}\n文件：${update.fileName}'
                    '${update.uploadTime == null ? '' : '\n上传时间：${update.uploadTime}'}',
                  ),
            actions: [
              if (!downloading)
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('暂不更新'),
                ),
              if (!downloading)
                FilledButton(
                  onPressed: () async {
                    setState(() {
                      downloading = true;
                      progress = 0;
                    });
                    try {
                      await _updateService.installUpdate(
                        update,
                        onProgress: (value) {
                          if (context.mounted) setState(() => progress = value);
                        },
                      );
                    } catch (e) {
                      if (context.mounted) {
                        setState(() => downloading = false);
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text('更新失败：$e')));
                      }
                    }
                  },
                  child: const Text('立即更新'),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _loadRecordCount() async {
    final count = await DatabaseService.instance.getRecordCount();
    if (mounted) {
      setState(() => _recordCount = count);
    }
  }

  void _loadInputSettings() async {
    final settings = await _databaseService.getAllSettings();
    final sourceStr = settings?['inputSource'] as String? ?? 'bluetooth';

    if (mounted) {
      final newSource = InputSource.values.firstWhere(
        (e) => e.name == sourceStr,
        orElse: () => InputSource.bluetooth,
      );

      setState(() {
        _inputSource = newSource;
        _rtlTcpConnected = _rtlTcpService.isConnected;
      });

      if (_inputSource == InputSource.rtlTcp && !_rtlTcpConnected) {
        final host = settings?['rtlTcpHost']?.toString() ?? '127.0.0.1';
        final port = settings?['rtlTcpPort']?.toString() ?? '14423';
        _connectToRtlTcp(host, port);
      } else if (_inputSource == InputSource.audioInput) {
        await AudioInputService().startListening();
        setState(() {});
      }
    }
  }

  Future<void> _checkAndStartBackgroundService() async {
    final settings = await DatabaseService.instance.getAllSettings() ?? {};
    final backgroundServiceEnabled =
        (settings['backgroundServiceEnabled'] ?? 0) == 1;

    if (backgroundServiceEnabled) {
      await BackgroundService.startService();
    }
  }

  void _setupLastReceivedTimeListener() {
    _lastReceivedTimeSubscription = _bleService.lastReceivedTimeStream.listen((
      time,
    ) {
      if (mounted) {
        setState(() {
          _lastReceivedTime = time;
        });
      }
    });

    _rtlTcpLastReceivedTimeSubscription = _rtlTcpService.lastReceivedTimeStream
        .listen((time) {
          if (mounted) {
            setState(() {
              _rtlTcpLastReceivedTime = time;
            });
          }
        });

    _audioLastReceivedTimeSubscription = AudioInputService()
        .lastReceivedTimeStream
        .listen((time) {
          if (mounted) {
            setState(() {
              _audioLastReceivedTime = time;
            });
          }
        });
  }

  void _setupSettingsListener() {
    _settingsSubscription = DatabaseService.instance.onSettingsChanged((
      settings,
    ) {
      if (mounted) {
        final sourceStr = settings['inputSource'] as String? ?? 'bluetooth';
        final newInputSource = InputSource.values.firstWhere(
          (e) => e.name == sourceStr,
          orElse: () => InputSource.bluetooth,
        );

        setState(() {
          _inputSource = newInputSource;
        });

        switch (newInputSource) {
          case InputSource.rtlTcp:
            setState(() {
              _rtlTcpConnected = _rtlTcpService.isConnected;
            });
            break;
          case InputSource.audioInput:
            setState(() {});
            break;
          case InputSource.bluetooth:
            _rtlTcpService.disconnect();
            setState(() {
              _rtlTcpConnected = false;
              _rtlTcpLastReceivedTime = null;
            });
            break;
        }

        _historyScreenKey.currentState?.reloadRecords();
      }
    });
  }

  void _setupConnectionListener() {
    _connectionSubscription = _bleService.connectionStream.listen((connected) {
      if (mounted) {
        setState(() {
          _isConnected = connected;
          if (!connected) _firmwareVersion = null;
        });
      }
    });

    _rtlTcpConnectionSubscription = _rtlTcpService.connectionStream.listen((
      connected,
    ) {
      if (mounted) {
        setState(() {
          _rtlTcpConnected = connected;
        });
      }
    });

    _audioConnectionSubscription = AudioInputService().connectionStream.listen((
      listening,
    ) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<void> _connectToRtlTcp(String host, String port) async {
    try {
      await _rtlTcpService.connect(host: host, port: port);
    } catch (e) {
      developer.log('rtl_tcp: connect_fail: $e');
    }
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _rtlTcpConnectionSubscription?.cancel();
    _audioConnectionSubscription?.cancel();
    _dataSubscription?.cancel();
    _rtlTcpDataSubscription?.cancel();
    _audioDataSubscription?.cancel();
    _lastReceivedTimeSubscription?.cancel();
    _rtlTcpLastReceivedTimeSubscription?.cancel();
    _audioLastReceivedTimeSubscription?.cancel();
    _firmwareVersionSubscription?.cancel();
    _settingsSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _bleService.onAppResume();
    }
  }

  Future<void> _initializeServices() async {
    await _notificationService.initialize();

    // Sync the user's notification preference (settings toggle) into the
    // service so the toggle actually gates notifications across restarts, and
    // ensure the Android 13+ runtime permission is granted when the user has
    // notifications enabled (idempotent — the system only prompts once).
    final settings = await DatabaseService.instance.getAllSettings() ?? {};
    final notificationsOn = (settings['notificationEnabled'] ?? 1) == 1;
    _notificationService.enableNotifications(notificationsOn);
    if (notificationsOn) {
      await _notificationService.requestPermission();
    }

    _dataSubscription = _bleService.dataStream.listen((record) {
      if (_inputSource == InputSource.bluetooth) {
        _processRecord(record);
      }
    });

    _rtlTcpDataSubscription = _rtlTcpService.dataStream.listen((record) {
      if (_inputSource == InputSource.rtlTcp) {
        _processRecord(record);
      }
    });

    _audioDataSubscription = AudioInputService().dataStream.listen((record) {
      if (_inputSource == InputSource.audioInput) {
        _processRecord(record);
      }
    });
  }

  void _processRecord(record) {
    _notificationService.showTrainNotification(record);
    _historyScreenKey.currentState?.addNewRecord(record);
    _recordCount++;
    if (mounted) setState(() {});
  }

  void _showConnectionDialog() {
    _bleService.setAutoConnectBlocked(true);
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => _PixelPerfectBluetoothDialog(
        bleService: _bleService,
        inputSource: _inputSource,
      ),
    ).then((_) {
      _bleService.setAutoConnectBlocked(false);
      if (_inputSource == InputSource.bluetooth &&
          !_bleService.isManualDisconnect) {
        _bleService.ensureConnection();
      }
    });
  }

  AppBar _buildAppBar(BuildContext context) {
    final historyState = _historyScreenKey.currentState;
    final selectedCount = historyState?.getSelectedCount() ?? 0;

    if (_currentIndex == 0 && _isHistoryEditMode) {
      return AppBar(
        backgroundColor: Theme.of(context).primaryColor,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: _handleHistoryCancelSelection,
        ),
        title: Text(
          '已选择 $selectedCount 项',
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.white),
            onPressed: selectedCount > 0 ? _handleHistoryDeleteSelected : null,
          ),
        ],
      );
    }

    final IconData statusIcon = switch (_inputSource) {
      InputSource.rtlTcp => Icons.wifi,
      InputSource.audioInput => Icons.mic,
      InputSource.bluetooth => Icons.bluetooth,
    };

    return AppBar(
      backgroundColor: AppTheme.primaryBlack,
      elevation: 0,
      title: Text(
        '${['列车记录', '设置'][_currentIndex]}${_currentIndex == 0 ? ' ($_recordCount)' : ''}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      centerTitle: false,
      actions: [
        Row(
          children: [
            _ConnectionStatusWidget(
              bleService: _bleService,
              rtlTcpService: _rtlTcpService,
              lastReceivedTime: _lastReceivedTime,
              rtlTcpLastReceivedTime: _rtlTcpLastReceivedTime,
              audioLastReceivedTime: _audioLastReceivedTime,
              inputSource: _inputSource,
              rtlTcpConnected: _rtlTcpConnected,
            ),
            IconButton(
              icon: Icon(statusIcon, color: Colors.white),
              onPressed: _showConnectionDialog,
            ),
          ],
        ),
      ],
    );
  }

  void _handleHistoryEditModeChanged(bool isEditing) {
    setState(() {
      _isHistoryEditMode = isEditing;
      if (!isEditing) {
        _historyScreenKey.currentState?.clearSelection();
      }
    });
  }

  void _handleSelectionChanged() {
    if (_isHistoryEditMode &&
        (_historyScreenKey.currentState?.getSelectedCount() ?? 0) == 0) {
      _handleHistoryCancelSelection();
    } else {
      setState(() {});
    }
  }

  void _handleHistoryCancelSelection() {
    _historyScreenKey.currentState?.setEditMode(false);
  }

  Future<void> _handleHistoryDeleteSelected() async {
    final historyState = _historyScreenKey.currentState;
    if (historyState == null || historyState.getSelectedCount() == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除选中的 ${historyState.getSelectedCount()} 条记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final idsToDelete = historyState.getSelectedRecordIds().toList();
      await DatabaseService.instance.deleteRecords(idsToDelete);

      historyState.setEditMode(false);
      historyState.reloadRecords();
      _loadRecordCount();
    }
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: AppTheme.primaryBlack,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    final pages = [
      HistoryScreen(
        key: _historyScreenKey,
        onEditModeChanged: _handleHistoryEditModeChanged,
        onSelectionChanged: _handleSelectionChanged,
      ),
      SettingsScreen(
        onSettingsChanged: () {},
        onCheckForUpdates: () => _checkForUpdate(showErrors: true),
        onCheckFirmwareUpdate: () => _checkFirmwareUpdate(showErrors: true),
        onWirelessBrickRecovery: _startWirelessBrickRecovery,
        firmwareVersion: _firmwareVersion,
        onChangeDeviceName: _changeBluetoothDeviceName,
        isBluetoothConnected: _isConnected,
        canChangeDeviceName: _bleService.canChangeDeviceName,
      ),
    ];

    return Scaffold(
      backgroundColor: AppTheme.primaryBlack,
      appBar: _buildAppBar(context),
      body: IndexedStack(index: _currentIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        backgroundColor: AppTheme.secondaryBlack,
        indicatorColor: AppTheme.accentBlue.withValues(alpha: 0.2),
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          if (index == 0) {
            _historyScreenKey.currentState?.reloadRecords();
            _loadRecordCount();
          }
          setState(() {
            if (_isHistoryEditMode) _isHistoryEditMode = false;
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.directions_railway),
            label: '列车记录',
          ),
          NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}

class _RescueDevicePickerDialog extends StatefulWidget {
  const _RescueDevicePickerDialog();

  @override
  State<_RescueDevicePickerDialog> createState() =>
      _RescueDevicePickerDialogState();
}

class _RescueDevicePickerDialogState extends State<_RescueDevicePickerDialog> {
  List<ClassicBluetoothDevice> _devices = const [];
  String? _selectedAddress;
  String _status = '正在搜索经典蓝牙设备…';
  String? _errorMessage;
  bool _loading = true;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    if (_loading && _devices.isNotEmpty) return;
    setState(() {
      _loading = true;
      _errorMessage = null;
      _status = '正在搜索经典蓝牙设备…';
    });
    try {
      final devices = await ClassicSppService.discoverDevices(
        timeout: const Duration(seconds: 10),
      );
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _loading = false;
        _selectedAddress =
            devices.any((device) => device.address == _selectedAddress)
            ? _selectedAddress
            : null;
        _status = devices.isEmpty ? '未发现蓝牙设备' : '请选择要救砖的设备';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = '设备搜索失败：$error';
        _status = '设备搜索失败';
      });
    }
  }

  ClassicBluetoothDevice? get _selectedDevice {
    final address = _selectedAddress;
    if (address == null) return null;
    for (final device in _devices) {
      if (device.address == address) return device;
    }
    return null;
  }

  Future<void> _pairSelected() async {
    final device = _selectedDevice;
    if (device == null || _connecting) return;

    setState(() {
      _connecting = true;
      _errorMessage = null;
      _status = device.isPaired
          ? '已选择 ${device.displayName}，准备连接…'
          : '请在系统蓝牙窗口中完成 ${device.displayName} 的配对…';
    });

    try {
      if (!device.isPaired) {
        final paired = await ClassicSppService.pair(
          device.address,
        ).timeout(const Duration(seconds: 60));
        if (!paired) throw StateError('设备配对未完成');
      }
      if (!mounted) return;
      Navigator.pop(
        context,
        device.isPaired
            ? device
            : ClassicBluetoothDevice(device: device.device, isPaired: true),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _errorMessage = '配对或连接失败：$error';
          _status = '请选择其他设备，或重新配对后再试';
        });
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Widget _buildDeviceGroup(String title, bool paired) {
    final devices = _devices.where((device) => device.isPaired == paired);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ...devices.map(
          (device) => RadioListTile<String>(
            value: device.address,
            title: Text(device.displayName),
            subtitle: Text(
              '${device.address}\n'
              '${device.hasSppService ? '已发现 SPP 服务' : '未发现 SPP 服务（仍可尝试）'}',
            ),
            secondary: Icon(
              device.hasSppService
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth,
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
            enabled: !_connecting,
          ),
        ),
        if (!devices.any((_) => true))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('暂无设备', style: TextStyle(color: Colors.white54)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedDevice;
    return PopScope(
      canPop: !_connecting,
      child: AlertDialog(
        title: const Text('选择无线救砖设备'),
        content: SizedBox(
          width: 520,
          height: 430,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_loading) const LinearProgressIndicator(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_errorMessage ?? _status),
              ),
              if (_loading)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Expanded(
                  child: Scrollbar(
                    child: RadioGroup<String>(
                      groupValue: _selectedAddress,
                      onChanged: (address) {
                        if (!_connecting && address != null) {
                          setState(() => _selectedAddress = address);
                        }
                      },
                      child: ListView(
                        children: [
                          _buildDeviceGroup('已配对设备', true),
                          _buildDeviceGroup('未配对设备', false),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _connecting ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: _loading || _connecting ? null : _loadDevices,
            child: const Text('重新搜索'),
          ),
          FilledButton(
            onPressed: selected == null || _loading || _connecting
                ? null
                : _pairSelected,
            child: Text(selected?.isPaired == true ? '选择此设备' : '配对并选择'),
          ),
        ],
      ),
    );
  }
}

enum _ScanState { initial, scanning, finished }

class _PixelPerfectBluetoothDialog extends StatefulWidget {
  final BLEService bleService;
  final InputSource inputSource;
  const _PixelPerfectBluetoothDialog({
    required this.bleService,
    required this.inputSource,
  });
  @override
  State<_PixelPerfectBluetoothDialog> createState() =>
      _PixelPerfectBluetoothDialogState();
}

class _PixelPerfectBluetoothDialogState
    extends State<_PixelPerfectBluetoothDialog> {
  List<BluetoothDevice> _devices = [];
  _ScanState _scanState = _ScanState.initial;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _lastReceivedTimeSubscription;
  DateTime? _lastReceivedTime;
  StreamSubscription? _rtlTcpConnectionSubscription;
  bool _rtlTcpConnected = false;

  @override
  void initState() {
    super.initState();
    _connectionSubscription = widget.bleService.connectionStream.listen((_) {
      if (mounted) setState(() {});
    });

    _rtlTcpConnectionSubscription = widget
        .bleService
        .rtlTcpService
        ?.connectionStream
        .listen((connected) {
          if (mounted) {
            setState(() {
              _rtlTcpConnected = connected;
            });
          }
        });

    if (widget.inputSource == InputSource.rtlTcp &&
        widget.bleService.rtlTcpService != null) {
      _rtlTcpConnected = widget.bleService.rtlTcpService!.isConnected;
    }

    if (!widget.bleService.isConnected &&
        widget.inputSource == InputSource.bluetooth) {
      _startScan();
    }
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _rtlTcpConnectionSubscription?.cancel();
    _lastReceivedTimeSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (_scanState == _ScanState.scanning) return;
    if (mounted) {
      setState(() {
        _scanState = _ScanState.scanning;
        _devices.clear();
      });
    }
    try {
      await widget.bleService.startScan(
        timeout: const Duration(seconds: 8),
        onScanResults: (devices) {
          if (mounted) setState(() => _devices = devices);
        },
      );
      await Future<void>.delayed(const Duration(seconds: 8));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('扫描失败：$e')));
    }
    if (mounted) setState(() => _scanState = _ScanState.finished);
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    try {
      await widget.bleService.connectManually(device);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('连接失败：$e')));
    }
  }

  Future<void> _disconnect() async {
    Navigator.pop(context);
    await widget.bleService.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final (String title, Widget content) = switch (widget.inputSource) {
      InputSource.rtlTcp => ('RTL-TCP 服务器', _buildRtlTcpView(context)),
      InputSource.audioInput => ('音频输入', _buildAudioInputView(context)),
      InputSource.bluetooth => (
        '蓝牙设备',
        widget.bleService.isConnected
            ? _buildConnectedView(context, widget.bleService.connectedDevice)
            : _buildDisconnectedView(context),
      ),
    };

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(child: content),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildConnectedView(BuildContext context, BluetoothDevice? device) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.bluetooth_connected, size: 48, color: Colors.green),
        const SizedBox(height: 16),
        Text(
          '设备已连接',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          widget.bleService.connectedDeviceName,
          textAlign: TextAlign.center,
        ),
        if (widget.bleService.connectedDeviceAddress != null)
          Text(
            widget.bleService.connectedDeviceAddress!,
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _disconnect,
          icon: const Icon(Icons.bluetooth_disabled),
          label: const Text('断开连接'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildDisconnectedView(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ElevatedButton.icon(
          onPressed: _scanState == _ScanState.scanning ? null : _startScan,
          icon: _scanState == _ScanState.scanning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.search),
          label: Text(_scanState == _ScanState.scanning ? '扫描中...' : '扫描设备'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(double.infinity, 40),
          ),
        ),
        const SizedBox(height: 16),
        if (_devices.isNotEmpty) _buildDeviceListView(),
      ],
    );
  }

  Widget _buildRtlTcpView(BuildContext context) {
    final isConnected = _rtlTcpConnected;
    final currentAddress =
        widget.bleService.rtlTcpService?.currentAddress ?? '未配置';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.wifi,
          size: 48,
          color: isConnected ? Colors.green : Colors.red,
        ),
        const SizedBox(height: 16),
        Text(
          isConnected ? '已连接' : '未连接',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          currentAddress,
          style: TextStyle(color: isConnected ? Colors.green : Colors.grey),
        ),
      ],
    );
  }

  Widget _buildAudioInputView(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [SizedBox(height: 8), AudioWaterfallWidget()],
    );
  }

  Widget _buildDeviceListView() {
    return SizedBox(
      height: 200,
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _devices.length,
        itemBuilder: (context, index) {
          final device = _devices[index];
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: const Icon(Icons.bluetooth),
              title: Text(
                device.platformName.isNotEmpty ? device.platformName : '未知设备',
              ),
              subtitle: Text(device.remoteId.str),
              onTap: () => _connectToDevice(device),
            ),
          );
        },
      ),
    );
  }
}
