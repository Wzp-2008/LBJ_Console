import 'package:lbjconsole/services/ble_diagnostics.dart';
import 'package:lbjconsole/services/ble_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'dart:developer' as developer;
import 'package:flutter_blue_plus_windows/flutter_blue_plus_windows.dart';
import 'package:lbjconsole/screens/history_screen.dart';
import 'package:lbjconsole/screens/settings_screen.dart';
import 'package:lbjconsole/services/ble_service.dart';
import 'package:lbjconsole/services/database_service.dart';
import 'package:lbjconsole/services/notification_service.dart';
import 'package:lbjconsole/services/background_service.dart';
import 'package:lbjconsole/themes/app_theme.dart';
import 'package:lbjconsole/services/app_update_service.dart';
import 'package:lbjconsole/services/firmware_ota_service.dart';
import 'package:lbjconsole/services/classic_spp_service.dart';
import 'package:lbjconsole/services/wired_recovery_service.dart';
import 'package:lbjconsole/screens/wired_recovery_dialogs.dart';
import 'package:lbjconsole/services/windows_tray_service.dart';
import 'package:lbjconsole/models/train_record.dart';
import 'package:lbjconsole/models/firmware_board.dart';

class _ConnectionStatusWidget extends StatelessWidget {
  final DateTime? lastReceivedTime;
  final bool isConnected;
  final String deviceStatus;

  const _ConnectionStatusWidget({
    required this.lastReceivedTime,
    required this.isConnected,
    required this.deviceStatus,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = isConnected ? Colors.green : Colors.red;
    final displayTime = lastReceivedTime;

    return Row(
      children: [
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (displayTime == null || !isConnected) ...[
              Text(
                deviceStatus,
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
  final NotificationService _notificationService = NotificationService.instance;

  StreamSubscription? _connectionSubscription;
  StreamSubscription? _dataSubscription;
  StreamSubscription? _lastReceivedTimeSubscription;
  Timer? _recordCountRefreshTimer;
  DateTime? _lastReceivedTime;
  bool _isHistoryEditMode = false;

  int _recordCount = 0;

  bool _isConnected = false;
  final GlobalKey<HistoryScreenState> _historyScreenKey =
      GlobalKey<HistoryScreenState>();
  late final AppUpdateService _updateService;
  late final FirmwareOtaService _firmwareOtaService;
  late final WiredRecoveryService _wiredRecoveryService;
  bool _checkingUpdate = false;
  bool _checkingFirmwareUpdate = false;
  bool _brickRecoveryActive = false;
  bool _wiredRecoveryActive = false;
  StreamSubscription<String>? _firmwareVersionSubscription;
  String? _firmwareVersion;
  FirmwareBoard? _sessionFirmwareBoard;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bleService = BLEService();
    _updateService = AppUpdateService();
    _firmwareOtaService = FirmwareOtaService(bleService: _bleService);
    _wiredRecoveryService = WiredRecoveryService();
    _bleService.initialize();
    _initializeServices();
    _checkAndStartBackgroundService();
    _setupConnectionListener();
    _setupLastReceivedTimeListener();
    _loadRecordCount();
    _firmwareVersionSubscription = _bleService.firmwareVersionStream.listen(
      (version) => unawaited(_handleFirmwareVersion(version)),
    );
    final knownFirmwareVersion = _bleService.firmwareVersion;
    if (knownFirmwareVersion != null) {
      _firmwareVersion = knownFirmwareVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_handleFirmwareVersion(knownFirmwareVersion));
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdate(showErrors: false, automatic: true);
    });
  }

  Future<void> _handleFirmwareVersion(String version) async {
    if (!mounted) return;
    final reportedBoard = _bleService.firmwareBoard;
    setState(() {
      _firmwareVersion = version;
      if (reportedBoard != null) _sessionFirmwareBoard = reportedBoard;
    });
    final address = _bleService.connectedDeviceAddress;
    if (reportedBoard != null && address != null && address.isNotEmpty) {
      await DatabaseService.instance.setDeviceBoard(address, reportedBoard);
    }
    await _checkFirmwareUpdate();
  }

  Future<void> _checkFirmwareUpdate({bool showErrors = false}) async {
    if (_checkingFirmwareUpdate ||
        !_bleService.isConnected ||
        _bleService.isOtaActive) {
      return;
    }
    _checkingFirmwareUpdate = true;
    try {
      final board = await _resolveConnectedFirmwareBoard();
      if (board == null) return;
      final update = await _firmwareOtaService.checkForUpdate(board);
      if (!mounted) return;
      if (update == null) {
        if (showErrors) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('当前固件已是最新版本，或分享站暂无匹配固件')),
          );
        }
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

  Future<FirmwareBoard?> _resolveConnectedFirmwareBoard() async {
    final known = _bleService.firmwareBoard ?? _sessionFirmwareBoard;
    if (known != null) return known;
    final selected = await _showFirmwareBoardPicker();
    if (selected == null || !mounted) return null;
    setState(() => _sessionFirmwareBoard = selected);
    final address = _bleService.connectedDeviceAddress;
    if (address != null && address.isNotEmpty) {
      await DatabaseService.instance.setDeviceBoard(address, selected);
    }
    return selected;
  }

  Future<FirmwareBoard?> _showFirmwareBoardPicker({bool forRescue = false}) {
    if (!mounted) return Future.value();
    return showDialog<FirmwareBoard>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择板型'),
        content: Text(
          '${forRescue ? '救砖模式无法通过 BLE 获取板型' : '设备未上报可识别的板型'}，'
          '请根据实际硬件选择。\n\n'
          '$firmwareBoardWarning',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, FirmwareBoard.lore32),
            child: const Text('lore32'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, FirmwareBoard.wzp),
            child: const Text('wzp'),
          ),
        ],
      ),
    );
  }

  Future<void> _changeBluetoothDeviceName(String name) async {
    await _bleService.setRemoteDeviceName(name);
  }

  Future<void> _showOtaProgressDialog({
    required String title,
    required String detail,
    required String actionLabel,
    required String cancelLabel,
    required Future<void> Function({
      void Function(double progress)? onProgress,
      void Function(Map<String, dynamic> state)? onState,
    })
    onInstall,
    required String successMessage,
    required String failureMessage,
    bool barrierDismissible = false,
    bool closeOnError = false,
  }) async {
    if (!mounted) return;
    var installing = false;
    var progress = 0.0;
    var otaState = '等待开始';
    await showDialog<void>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => PopScope(
          canPop: !installing,
          child: AlertDialog(
            title: Text(title),
            content: installing
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(value: progress),
                      const SizedBox(height: 12),
                      Text('$otaState ${(progress * 100).toStringAsFixed(0)}%'),
                    ],
                  )
                : Text(detail),
            actions: [
              if (!installing)
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(cancelLabel),
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
                      await onInstall(
                        onProgress: (value) {
                          if (context.mounted) setState(() => progress = value);
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
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      if (mounted) {
                        ScaffoldMessenger.of(
                          this.context,
                        ).showSnackBar(SnackBar(content: Text(successMessage)));
                      }
                    } catch (error, stack) {
                      BleDiagnostics.log('$title failed', error, stack);
                      if (closeOnError && dialogContext.mounted) {
                        Navigator.pop(dialogContext);
                      }
                      if (!closeOnError && context.mounted) {
                        setState(() => installing = false);
                      }
                      if (mounted) {
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          SnackBar(
                            content: Text(
                              '$failureMessage：$error\n日志：${BleDiagnostics.logPath}',
                            ),
                          ),
                        );
                      }
                    }
                  },
                  child: Text(actionLabel),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showFirmwareUpdateDialog(FirmwareUpdateInfo update) {
    return _showOtaProgressDialog(
      title: '发现新固件',
      detail:
          '当前固件：${_bleService.firmwareVersion ?? '未知'}\n'
          '板型：${update.board.displayName}\n'
          '最新固件：${update.version}\n文件：${update.fileName}'
          '${update.uploadTime == null ? '' : '\n上传时间：${update.uploadTime}'}\n\n'
          '$firmwareBoardWarning',
      actionLabel: '升级固件',
      cancelLabel: '暂不更新',
      onInstall: ({onProgress, onState}) => _firmwareOtaService.installUpdate(
        update,
        onProgress: onProgress,
        onState: onState,
      ),
      successMessage: '固件升级成功，设备即将重启',
      failureMessage: '固件升级失败',
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

      final board = await _resolveRescueFirmwareBoard(device.address);
      if (!mounted || board == null) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已选择 ${device.displayName}（${board.displayName}），正在查询最新固件',
          ),
        ),
      );
      final update = await _firmwareOtaService.findLatestFirmware(board);
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

  Future<FirmwareBoard?> _resolveRescueFirmwareBoard(String address) async {
    final history = await DatabaseService.instance.getDeviceBoard(address);
    if (!mounted) return null;
    FirmwareBoard? selected;
    if (history != null) {
      final action = await showDialog<_BoardHistoryAction>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认救砖板型'),
          content: Text(
            '根据历史蓝牙连接情况，自动选择板型 '
            '${history.displayName}，若不是该板型请手动选择。\n\n'
            '$firmwareBoardWarning',
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                _BoardHistoryAction.chooseManually,
              ),
              child: const Text('手动选择'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _BoardHistoryAction.confirm),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      if (action == null) return null;
      if (action == _BoardHistoryAction.confirm) return history;
      selected = await _showFirmwareBoardPicker(forRescue: true);
    } else {
      selected = await _showFirmwareBoardPicker(forRescue: true);
    }
    if (selected != null) {
      await DatabaseService.instance.setDeviceBoard(address, selected);
    }
    return selected;
  }

  Future<void> _startWiredBrickRecovery() async {
    if (!Platform.isWindows || _wiredRecoveryActive) return;
    _wiredRecoveryActive = true;
    try {
      await showWiredRecoveryWorkflow(
        context,
        service: _wiredRecoveryService,
        onCriticalOperation: (active) =>
            WindowsTrayService.instance.setCriticalOperationActive(active),
      );
    } finally {
      _wiredRecoveryActive = false;
    }
  }

  Future<ClassicBluetoothDevice?> _findRescueSppDevice() {
    if (!mounted) return Future.value();
    return showDialog<ClassicBluetoothDevice>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => const RescueDevicePickerDialog(),
    );
  }

  Future<void> _showRescueFirmwareDialog(
    FirmwareUpdateInfo update,
    ClassicBluetoothDevice device,
  ) {
    return _showOtaProgressDialog(
      title: '无线救砖升级',
      detail:
          '设备：${device.displayName}\n'
          '运行模式：Updater SPP\n'
          '板型：${update.board.displayName}\n'
          '最新固件：${update.version}\n'
          '文件：${update.fileName}'
          '${update.uploadTime == null ? '' : '\n上传时间：${update.uploadTime}'}\n\n'
          '升级过程中请勿关闭程序或断开蓝牙。\n\n'
          '$firmwareBoardWarning',
      actionLabel: '开始刷写',
      cancelLabel: '取消',
      onInstall: ({onProgress, onState}) =>
          _firmwareOtaService.installSppUpdate(
            update,
            connectSpp: () =>
                ClassicSppService.connectOtaTransport(device.address),
            onProgress: onProgress,
            onState: onState,
          ),
      successMessage: '无线救砖升级成功，设备即将重启',
      failureMessage: '无线救砖升级失败',
      closeOnError: true,
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
      if (!mounted) return;
      if (update == null) {
        if (showErrors) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
        }
        return;
      }
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
  }) {
    if (!mounted) return Future.value();
    return _showOtaProgressDialog(
      title: '发现新版本',
      detail:
          '当前版本：$appBuildHash\n最新版本：${update.hash}\n文件：${update.fileName}'
          '${update.uploadTime == null ? '' : '\n上传时间：${update.uploadTime}'}',
      actionLabel: '立即更新',
      cancelLabel: '暂不更新',
      onInstall: ({onProgress, onState}) =>
          _updateService.installUpdate(update, onProgress: onProgress),
      successMessage: '安装器已打开，请完成安装',
      failureMessage: '更新失败',
      barrierDismissible: !automatic,
    );
  }

  Future<void> _loadRecordCount() async {
    final count = await DatabaseService.instance.getRecordCount();
    if (mounted) {
      setState(() => _recordCount = count);
    }
  }

  void _scheduleRecordCountRefresh() {
    if (_recordCountRefreshTimer != null) return;
    _recordCountRefreshTimer = Timer(const Duration(milliseconds: 300), () {
      _recordCountRefreshTimer = null;
      _loadRecordCount();
    });
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
  }

  void _setupConnectionListener() {
    _connectionSubscription = _bleService.connectionStream.listen((connected) {
      if (mounted) {
        setState(() {
          _isConnected = connected;
          if (!connected) {
            _firmwareVersion = null;
            _sessionFirmwareBoard = null;
          }
        });
      }
    });
    _isConnected = _bleService.isConnected;
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _dataSubscription?.cancel();
    _lastReceivedTimeSubscription?.cancel();
    _firmwareVersionSubscription?.cancel();
    _recordCountRefreshTimer?.cancel();
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
    try {
      await _notificationService.initialize();
    } catch (e, stack) {
      developer.log('通知服务初始化失败：$e', name: 'MainScreen', stackTrace: stack);
    }

    // Sync the user's notification preference (settings toggle) into the
    // service so the toggle actually gates notifications across restarts, and
    // ensure the Android 13+ runtime permission is granted when the user has
    // notifications enabled (idempotent — the system only prompts once).
    final settings = await DatabaseService.instance.getAllSettings() ?? {};
    final notificationsOn = (settings['notificationEnabled'] ?? 1) == 1;
    await _notificationService.enableNotifications(notificationsOn);
    if (notificationsOn) {
      try {
        await _notificationService.requestPermission();
      } catch (e, stack) {
        developer.log('通知权限请求失败：$e', name: 'MainScreen', stackTrace: stack);
      }
    }

    _dataSubscription = _bleService.dataStream.listen((record) {
      _processRecord(record);
    });
  }

  void _processRecord(TrainRecord record) {
    _notificationService.showTrainNotification(record);
    _historyScreenKey.currentState?.addNewRecord(record);
    _scheduleRecordCountRefresh();
  }

  void _showConnectionDialog() {
    _bleService.setAutoConnectBlocked(true);
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) =>
          _PixelPerfectBluetoothDialog(
            bleService: _bleService,
            sessionFirmwareBoard: _sessionFirmwareBoard,
          ),
    ).then((_) {
      _bleService.setAutoConnectBlocked(false);
      if (!_bleService.isManualDisconnect) {
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
              lastReceivedTime: _lastReceivedTime,
              isConnected: _isConnected,
              deviceStatus: _bleService.deviceStatus,
            ),
            IconButton(
              icon: const Icon(Icons.bluetooth, color: Colors.white),
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
        onWiredBrickRecovery: _startWiredBrickRecovery,
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
        indicatorColor: AppTheme.navigationIndicator,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: Colors.white54),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected)
                ? Colors.white
                : Colors.white70,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
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

enum _BoardHistoryAction { chooseManually, confirm }

class RescueDevicePickerDialog extends StatefulWidget {
  const RescueDevicePickerDialog({super.key, this.discovery});

  final ClassicSppDiscoverySession? discovery;

  @override
  State<RescueDevicePickerDialog> createState() =>
      _RescueDevicePickerDialogState();
}

class _RescueDevicePickerDialogState extends State<RescueDevicePickerDialog> {
  late final ClassicSppDiscoverySession _discovery;
  final _deviceScrollController = ScrollController();
  StreamSubscription<List<ClassicBluetoothDevice>>? _discoverySubscription;
  List<ClassicBluetoothDevice> _pairedDevices = const [];
  List<ClassicBluetoothDevice> _unpairedDevices = const [];
  String? _selectedAddress;
  String _status = '准备搜索经典蓝牙设备…';
  String? _errorMessage;
  bool _loading = false;
  bool _canRescan = false;
  bool _connecting = false;
  bool _showAllDevices = false;
  int _scanGeneration = 0;

  List<ClassicBluetoothDevice> get _visiblePairedDevices => _showAllDevices
      ? _pairedDevices
      : _pairedDevices.where((device) => device.isRecoveryDevice).toList();

  List<ClassicBluetoothDevice> get _visibleUnpairedDevices => _showAllDevices
      ? _unpairedDevices
      : _unpairedDevices.where((device) => device.isRecoveryDevice).toList();

  @override
  void initState() {
    super.initState();
    _discovery = widget.discovery ?? ClassicSppDiscoverySession();
    _discoverySubscription = _discovery.updates.listen(_applyDevices);
    unawaited(_startScan());
  }

  @override
  void dispose() {
    _discoverySubscription?.cancel();
    _deviceScrollController.dispose();
    unawaited(_discovery.dispose());
    super.dispose();
  }

  void _applyDevices(List<ClassicBluetoothDevice> devices) {
    if (!mounted) return;
    final paired = devices.where((device) => device.isPaired).toList();
    final unpaired = devices.where((device) => !device.isPaired).toList();
    setState(() {
      _pairedDevices = paired;
      _unpairedDevices = unpaired;
      if (_selectedAddress != null &&
          !devices.any(
            (device) =>
                device.address == _selectedAddress &&
                (_showAllDevices || device.isRecoveryDevice),
          )) {
        _selectedAddress = null;
      }
      _refreshDiscoveryStatus(scanning: _loading);
    });
  }

  void _refreshDiscoveryStatus({required bool scanning}) {
    if (_errorMessage != null) return;
    final allCount = _pairedDevices.length + _unpairedDevices.length;
    final visibleCount =
        _visiblePairedDevices.length + _visibleUnpairedDevices.length;
    if (scanning) {
      final recoveryCount = [..._pairedDevices, ..._unpairedDevices]
          .where((device) => device.isRecoveryDevice)
          .length;
      _status = _showAllDevices
          ? '正在搜索蓝牙设备，已发现 $allCount 台'
          : '正在搜索救砖设备，已发现 $recoveryCount 台匹配设备（全部设备 $allCount 台）';
      return;
    }
    _status = visibleCount == 0
        ? (_showAllDevices
              ? '未发现蓝牙设备'
              : allCount == 0
              ? '未发现 CoD 0x801FFC 救砖设备'
              : '已发现 $allCount 台蓝牙设备，但没有匹配 CoD 0x801FFC 救砖设备')
        : '请选择要救砖的设备';
  }

  Future<void> _startScan() async {
    if (_loading || _connecting) return;
    final generation = ++_scanGeneration;
    setState(() {
      _loading = true;
      _canRescan = false;
      _errorMessage = null;
      _unpairedDevices = const [];
      if (_selectedAddress != null &&
          !_pairedDevices.any((device) => device.address == _selectedAddress)) {
        _selectedAddress = null;
      }
      _status = '正在加载已配对设备…';
    });
    try {
      await _discovery.start(timeout: const Duration(seconds: 16));
      if (!mounted || generation != _scanGeneration) return;
      setState(() {
        _loading = false;
        _canRescan = true;
        _refreshDiscoveryStatus(scanning: false);
      });
    } catch (error) {
      if (!mounted || generation != _scanGeneration) return;
      setState(() {
        _loading = false;
        _canRescan = true;
        _errorMessage = '设备搜索失败：$error';
        _status = '设备搜索失败';
      });
    }
  }

  Future<void> _stopScanForSelection() async {
    if (!_loading) return;
    ++_scanGeneration;
    await _discovery.stop();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _canRescan = true;
      _status = '扫描已停止，请确认设备后继续';
    });
  }

  ClassicBluetoothDevice? get _selectedDevice {
    final address = _selectedAddress;
    if (address == null) return null;
    for (final device in [..._pairedDevices, ..._unpairedDevices]) {
      if (device.address == address) return device;
    }
    return null;
  }

  Future<void> _pairSelected() async {
    final device = _selectedDevice;
    if (device == null || _connecting) return;

    if (_loading) {
      await _stopScanForSelection();
    }
    if (!mounted) return;
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

  Widget _buildDeviceGroup(
    String title,
    List<ClassicBluetoothDevice> devices, {
    required bool searching,
  }) {
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
        ...devices.map((device) {
          final cod = device.classOfDevice;
          final codDescription = device.isRecoveryDevice
              ? '救砖设备 · CoD 0x801FFC'
              : cod == null
              ? 'CoD 未知'
              : 'CoD ${formatClassOfDevice(cod)}';
          return RadioListTile<String>(
            value: device.address,
            selected: _selectedAddress == device.address,
            title: Text(device.displayName),
            subtitle: Text(
              '${device.address}\n'
              '$codDescription\n'
              '${device.hasSppService ? '已发现 SPP 服务' : '未发现 SPP 服务（仍可尝试）'}',
            ),
            secondary: Icon(
              device.isRecoveryDevice
                  ? Icons.build_circle_outlined
                  : device.hasSppService
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth,
              color: device.isRecoveryDevice ? Colors.green : null,
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
            tileColor: Colors.transparent,
            selectedTileColor: Colors.transparent,
            hoverColor: Colors.transparent,
            enabled: !_connecting,
          );
        }),
        if (devices.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              searching ? '正在扫描…' : '暂无设备',
              style: const TextStyle(color: Colors.white54),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedDevice;
    final visiblePaired = _visiblePairedDevices;
    final visibleUnpaired = _visibleUnpairedDevices;
    return PopScope(
      canPop: !_connecting,
      child: AlertDialog(
        title: const Text('选择无线救砖设备（SPP）'),
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
              if (!_showAllDevices)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _connecting
                        ? null
                        : () {
                            setState(() {
                              _showAllDevices = true;
                              _status = _loading
                                  ? '正在搜索全部蓝牙设备…'
                                  : '已显示全部设备，请手动确认';
                            });
                          },
                    icon: const Icon(Icons.visibility),
                    label: const Text('显示全部设备'),
                  ),
                ),
              Expanded(
                child: Scrollbar(
                  controller: _deviceScrollController,
                  child: RadioGroup<String>(
                    groupValue: _selectedAddress,
                    onChanged: (address) {
                      if (!_connecting && address != null) {
                        setState(() => _selectedAddress = address);
                        if (_loading) unawaited(_stopScanForSelection());
                      }
                    },
                    child: ListView(
                      controller: _deviceScrollController,
                      children: [
                        _buildDeviceGroup(
                          '已配对设备',
                          visiblePaired,
                          searching: false,
                        ),
                        _buildDeviceGroup(
                          '未配对设备',
                          visibleUnpaired,
                          searching: _loading,
                        ),
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
            onPressed: !_canRescan || _loading || _connecting
                ? null
                : _startScan,
            child: const Text('重新扫描'),
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
  final FirmwareBoard? sessionFirmwareBoard;

  const _PixelPerfectBluetoothDialog({
    required this.bleService,
    this.sessionFirmwareBoard,
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
  StreamSubscription<String>? _firmwareVersionSubscription;

  @override
  void initState() {
    super.initState();
    _connectionSubscription = widget.bleService.connectionStream.listen((_) {
      if (mounted) setState(() {});
    });
    _firmwareVersionSubscription = widget.bleService.firmwareVersionStream
        .listen((_) {
          if (mounted) setState(() {});
        });

    if (!widget.bleService.isConnected) {
      _startScan();
    }
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _firmwareVersionSubscription?.cancel();
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
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('扫描失败：$e')));
      }
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
    return AlertDialog(
      title: const Text('BLE 设备'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: widget.bleService.isConnected
              ? _buildConnectedView(context, widget.bleService.connectedDevice)
              : _buildDisconnectedView(context),
        ),
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
    final board =
        widget.bleService.firmwareBoard ?? widget.sessionFirmwareBoard;
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
        const SizedBox(height: 4),
        Text('设备类型：${board?.displayName ?? '未知'}'),
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
          label: Text(
            _scanState == _ScanState.scanning ? '扫描 BLE 中...' : '扫描 BLE 设备',
          ),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(double.infinity, 40),
          ),
        ),
        const SizedBox(height: 16),
        if (_devices.isNotEmpty) _buildDeviceListView(),
      ],
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
