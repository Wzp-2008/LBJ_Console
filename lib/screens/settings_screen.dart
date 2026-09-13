import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:lbjconsole/services/ble_service.dart';
import 'package:lbjconsole/services/ble_diagnostics.dart';

import 'package:lbjconsole/services/database_service.dart';
import 'package:lbjconsole/services/background_service.dart';
import 'package:lbjconsole/services/notification_service.dart';
import 'package:lbjconsole/services/map_state_service.dart';
import 'package:lbjconsole/themes/app_theme.dart';

import 'package:file_picker/file_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:lbjconsole/services/app_update_service.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback? onSettingsChanged;
  final VoidCallback? onCheckForUpdates;
  final VoidCallback? onCheckFirmwareUpdate;
  final Future<void> Function()? onWiredBrickRecovery;
  final Future<void> Function()? onWirelessBrickRecovery;
  final String? firmwareVersion;
  final Future<void> Function(String name)? onChangeDeviceName;
  final bool isBluetoothConnected;
  final bool canChangeDeviceName;

  const SettingsScreen({
    super.key,
    this.onSettingsChanged,
    this.onCheckForUpdates,
    this.onCheckFirmwareUpdate,
    this.onWiredBrickRecovery,
    this.onWirelessBrickRecovery,
    this.firmwareVersion,
    this.onChangeDeviceName,
    this.isBluetoothConnected = false,
    this.canChangeDeviceName = false,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late DatabaseService _databaseService;

  bool _settingsLoaded = false;
  final Set<String> _pendingSettings = <String>{};

  bool _backgroundServiceEnabled = false;
  bool _notificationsEnabled = true;
  bool _mergeRecordsEnabled = false;
  bool _hideUngroupableRecords = false;
  bool _changingDeviceName = false;

  @override
  void initState() {
    super.initState();
    _databaseService = DatabaseService.instance;
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settingsMap = await _databaseService.getAllSettings() ?? {};
    if (mounted) {
      setState(() {
        _applySettings(settingsMap);
        _settingsLoaded = true;
        _pendingSettings.clear();
      });
    }
  }

  void _applySettings(Map<String, dynamic> settings) {
    if (!_pendingSettings.contains('backgroundServiceEnabled')) {
      _backgroundServiceEnabled =
          (settings['backgroundServiceEnabled'] ?? 0) == 1;
    }
    if (!_pendingSettings.contains('notificationEnabled')) {
      _notificationsEnabled = (settings['notificationEnabled'] ?? 1) == 1;
    }
    if (!_pendingSettings.contains('mergeRecordsEnabled')) {
      _mergeRecordsEnabled = (settings['mergeRecordsEnabled'] ?? 0) == 1;
    }
    if (!_pendingSettings.contains('hideUngroupableRecords')) {
      _hideUngroupableRecords = (settings['hideUngroupableRecords'] ?? 0) == 1;
    }
  }

  Map<String, dynamic> _collectSettings({bool reset = false}) => {
    'backgroundServiceEnabled': reset ? 0 : (_backgroundServiceEnabled ? 1 : 0),
    'notificationEnabled': reset ? 1 : (_notificationsEnabled ? 1 : 0),
    'mergeRecordsEnabled': reset ? 0 : (_mergeRecordsEnabled ? 1 : 0),
    'hideUngroupableRecords': reset ? 0 : (_hideUngroupableRecords ? 1 : 0),
    if (reset) 'specifiedDeviceAddress': null,
  };

  Future<void> _openBrickRecoveryMode() async {
    if (Platform.isAndroid) {
      await widget.onWirelessBrickRecovery?.call();
      return;
    }
    final mode = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('救砖模式'),
        content: const Text(
          '无线模式适用于已经进入 Updater SPP 模式的预警器。\n'
          '程序会列出已配对和未配对的蓝牙设备，请手动选择目标设备。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          if (Platform.isWindows && widget.onWiredBrickRecovery != null)
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(dialogContext, 'wired'),
              icon: const Icon(Icons.usb),
              label: const Text('有线救砖'),
            ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, 'wireless'),
            icon: const Icon(Icons.bluetooth),
            label: const Text('无线救砖'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (mode == 'wired') {
      await widget.onWiredBrickRecovery?.call();
    } else if (mode == 'wireless') {
      await widget.onWirelessBrickRecovery?.call();
    }
  }

  Future<void> _saveSetting(String key, dynamic value) async {
    _pendingSettings.add(key);
    await _databaseService.setSetting(key, value);
    if (mounted && _settingsLoaded) {
      setState(() => _pendingSettings.remove(key));
    }
    widget.onSettingsChanged?.call();
  }

  Future<void> _changeRemoteDeviceName() async {
    final callback = widget.onChangeDeviceName;
    if (callback == null) return;
    final controller = TextEditingController(
      text: BLEService().connectedDeviceName,
    );
    var saving = false;
    String? error;
    setState(() => _changingDeviceName = true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => PopScope(
            canPop: !saving,
            child: AlertDialog(
              title: const Text('修改设备广播名称'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('设备地址：${BLEService().connectedDeviceAddress ?? "未知"}'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    enabled: !saving,
                    decoration: InputDecoration(
                      labelText: '新名称',
                      errorText: error,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '最多 16 个 UTF-8 字节（中文通常占 3 字节）。\n保存后需重启设备生效；重连仍使用设备地址。',
                  ),
                  if (saving) const LinearProgressIndicator(),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          final name = controller.text.trim();
                          if (name.isEmpty ||
                              utf8.encode(name).length > 16 ||
                              name.runes.any((r) => r < 32 || r == 127)) {
                            update(() => error = '名称不能为空、含控制字符或超过 16 字节');
                            return;
                          }
                          update(() {
                            saving = true;
                            error = null;
                          });
                          try {
                            await callback(name);
                            if (!context.mounted) return;
                            update(() => saving = false);
                            Navigator.pop(dialogContext);
                            if (mounted) {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                const SnackBar(
                                  content: Text('设备名称已保存，请重启设备后生效'),
                                ),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              update(() {
                                saving = false;
                                error = e.toString();
                              });
                            }
                          }
                        },
                  child: const Text('保存到设备'),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      // Dialog route transition may still be using its text field.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      controller.dispose();
      if (mounted) setState(() => _changingDeviceName = false);
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  Widget _buildBluetoothSettings() {
    return _buildSettingsCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.input, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              const Text('蓝牙设置', style: AppTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 16),

          const SizedBox(height: 16),
          Text(
            '已记住的设备地址：${BLEService().connectedDeviceAddress ?? "尚未选择"}',
            style: AppTheme.bodyMedium,
          ),
          const Text(
            '首次请在蓝牙设备列表中手动选择。连接成功后按地址自动重连，扫描不筛选名称。',
            style: AppTheme.caption,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed:
                widget.isBluetoothConnected &&
                    widget.canChangeDeviceName &&
                    !_changingDeviceName &&
                    !BLEService().isOtaActive
                ? _changeRemoteDeviceName
                : null,
            icon: _changingDeviceName
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.edit, size: 18),
            label: const Text('修改设备名称'),
          ),
          const SizedBox(height: 4),
          const Text('名称最多 16 个 UTF-8 字节，保存后需重启设备生效', style: AppTheme.caption),
        ],
      ),
    );
  }

  Widget _buildSettingsCard(Widget child) {
    return Card(
      color: AppTheme.tertiaryBlack,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.0)),
      child: Padding(padding: const EdgeInsets.all(20.0), child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildBluetoothSettings(),
          const SizedBox(height: 20),
          _buildAppSettings(),
          const SizedBox(height: 20),
          _buildMergeSettings(),
          const SizedBox(height: 20),
          _buildDataManagement(),
          const SizedBox(height: 20),
          _buildAboutSection(),
        ],
      ),
    );
  }

  Widget _buildAppSettings() {
    return _buildSettingsCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.settings,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              const Text('应用设置', style: AppTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 16),
          Platform.isWindows
              ? const SizedBox()
              : Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [Text('后台保活服务', style: AppTheme.bodyLarge)],
                    ),
                    Switch(
                      value: _backgroundServiceEnabled,
                      onChanged: (value) async {
                        setState(() {
                          _backgroundServiceEnabled = value;
                        });
                        await _saveSetting(
                          'backgroundServiceEnabled',
                          value ? 1 : 0,
                        );

                        if (value) {
                          await BackgroundService.startService();
                        } else {
                          await BackgroundService.stopService();
                        }
                      },
                      activeThumbColor: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
          SizedBox(height: Platform.isWindows ? 0 : 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Text('通知服务', style: AppTheme.bodyLarge)],
              ),
              Switch(
                value: _notificationsEnabled,
                onChanged: (value) async {
                  _pendingSettings.add('notificationEnabled');
                  setState(() {
                    _notificationsEnabled = value;
                  });
                  // Sync the user-intent flag so the toggle actually gates
                  // notifications, then request the runtime permission when
                  // turning on (Android 13+).
                  await NotificationService.instance.enableNotifications(value);
                  if (value) {
                    final granted = await NotificationService.instance
                        .requestPermission();
                    if (!granted && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('通知权限未授予，请在系统设置中开启通知权限')),
                      );
                    }
                  }
                  await _saveSetting('notificationEnabled', value ? 1 : 0);
                },
                activeThumbColor: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMergeSettings() {
    return _buildSettingsCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.merge_type,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              const Text('记录合并', style: AppTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Text('启用记录合并', style: AppTheme.bodyLarge)],
              ),
              Switch(
                value: _mergeRecordsEnabled,
                onChanged: (value) async {
                  setState(() {
                    _mergeRecordsEnabled = value;
                  });
                  await _saveSetting('mergeRecordsEnabled', value ? 1 : 0);
                },
                activeThumbColor: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('隐藏不可分组记录', style: AppTheme.bodyLarge),
                      Text(
                        '无车次和机车号的记录',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                  Switch(
                    value: _hideUngroupableRecords,
                    onChanged: (value) async {
                      setState(() {
                        _hideUngroupableRecords = value;
                      });
                      await _saveSetting(
                        'hideUngroupableRecords',
                        value ? 1 : 0,
                      );
                    },
                    activeThumbColor: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDataManagement() {
    return _buildSettingsCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.storage, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              const Text('数据管理', style: AppTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 16),
          _buildActionButton(
            icon: Icons.share,
            title: '分享数据',
            subtitle: '将记录分享为 JSON 文件',
            onTap: _shareData,
          ),
          const SizedBox(height: 12),
          _buildActionButton(
            icon: Icons.file_download,
            title: '导入数据',
            subtitle: '从 JSON 文件导入记录和设置',
            onTap: _importData,
          ),
          if (Platform.isWindows) ...[
            const SizedBox(height: 12),
            _buildActionButton(
              icon: Icons.usb,
              title: '从盘符导入 CSV',
              subtitle: '读取 U 盘 CSVTEST 文件夹中的所有 CSV 文件',
              onTap: _importCsvFromDrive,
            ),
          ],
          const SizedBox(height: 12),
          _buildActionButton(
            icon: Icons.cached,
            title: '重建合并缓存',
            subtitle: '修复合并卡片显示陈旧/错误数据',
            onTap: _rebuildMergeCache,
          ),
          const SizedBox(height: 12),
          _buildActionButton(
            icon: Icons.clear_all,
            title: '清空数据',
            subtitle: '删除所有记录和设置',
            onTap: _clearAllData,
            isDestructive: true,
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12.0),
      child: Container(
        padding: const EdgeInsets.all(12.0),
        decoration: BoxDecoration(
          color: isDestructive
              ? Colors.red.withValues(alpha: 0.1)
              : AppTheme.secondaryBlack,
          borderRadius: BorderRadius.circular(12.0),
          border: Border.all(
            color: isDestructive
                ? Colors.red.withValues(alpha: 0.3)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isDestructive
                  ? Colors.red
                  : Theme.of(context).colorScheme.primary,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTheme.bodyLarge.copyWith(
                      color: isDestructive ? Colors.red : Colors.white,
                    ),
                  ),
                  Text(subtitle, style: AppTheme.caption),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white54, size: 20),
          ],
        ),
      ),
    );
  }

  Future<String> _getAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      return 'v${packageInfo.version}';
    } catch (e) {
      return '';
    }
  }

  void _showBlockingDialog(String message) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Text(message),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirm(
    String title,
    String content, {
    String confirmLabel = '继续',
    bool destructive = false,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: destructive
                    ? TextButton.styleFrom(foregroundColor: Colors.red)
                    : null,
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _shareData() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    try {
      _showBlockingDialog('正在准备分享数据...');

      try {
        final exportedPath = await _databaseService.exportDataAsJson();
        if (mounted) {
          Navigator.pop(context);
        }

        if (exportedPath != null) {
          final file = File(exportedPath);
          await SharePlus.instance.share(
            ShareParams(subject: "LBJ Console Data", files: [XFile(file.path)]),
          );
        } else {
          scaffoldMessenger.showSnackBar(
            const SnackBar(content: Text('分享失败：无法生成数据文件')),
          );
        }
      } catch (e) {
        if (mounted) {
          Navigator.pop(context);
        }
        scaffoldMessenger.showSnackBar(SnackBar(content: Text('分享错误：$e')));
      }
    } catch (e) {
      scaffoldMessenger.showSnackBar(SnackBar(content: Text('分享错误：$e')));
    }
  }

  Future<void> _importData() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    final result = await _confirm('导入数据', '导入将替换所有现有数据，是否继续？');

    if (result != true) return;

    final resultFile = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (resultFile == null) return;
    final selectedFile = resultFile.files.single.path;
    if (selectedFile == null) return;
    if (mounted) {
      _showBlockingDialog('正在导入数据...');
    }

    try {
      final success = await _databaseService.importDataFromJson(selectedFile);
      if (mounted) {
        Navigator.pop(context);
      }

      if (success) {
        scaffoldMessenger.showSnackBar(const SnackBar(content: Text('数据导入成功')));

        await _loadSettings();
      } else {
        scaffoldMessenger.showSnackBar(const SnackBar(content: Text('数据导入失败')));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
      }
      scaffoldMessenger.showSnackBar(SnackBar(content: Text('导入错误：$e')));
    }
  }

  Future<void> _importCsvFromDrive() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    // CSV import replaces all existing data, same as the JSON import above.
    final confirmed = await _confirm('从盘符导入 CSV', '导入将替换所有现有数据，是否继续？');
    if (confirmed != true) return;
    if (!mounted) return;

    // Pick a drive letter: scans A-Z for drives whose CSVTEST folder holds at
    // least one .csv; falls back to manual entry if detection misses.
    final drive = await showDialog<String>(
      context: context,
      builder: (context) => const _DrivePickerDialog(),
    );
    if (drive == null || drive.isEmpty) return;

    if (mounted) {
      _showBlockingDialog('正在读取并导入 CSV...');
    }

    try {
      final result = await _databaseService.importCsvFromDrive(drive);
      if (mounted) {
        Navigator.pop(context);
      }
      scaffoldMessenger.showSnackBar(SnackBar(content: Text(result.message)));
      if (result.success) {
        await _loadSettings();
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
      }
      scaffoldMessenger.showSnackBar(SnackBar(content: Text('导入错误：$e')));
    }
  }

  Future<void> _rebuildMergeCache() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    if (mounted) {
      _showBlockingDialog('正在重建合并缓存...');
    }

    try {
      await _databaseService.rebuildMergeCache();
      if (mounted) Navigator.pop(context);
      scaffoldMessenger.showSnackBar(const SnackBar(content: Text('合并缓存已重建')));
      // Trigger the history list to reload with the fresh summaries.
      widget.onSettingsChanged?.call();
    } catch (e) {
      if (mounted) Navigator.pop(context);
      scaffoldMessenger.showSnackBar(SnackBar(content: Text('重建错误：$e')));
    }
  }

  Future<void> _clearAllData() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    final result = await _confirm(
      '清空数据',
      '此操作将删除所有记录和设置，无法撤销。是否继续？',
      confirmLabel: '确认清空',
      destructive: true,
    );

    if (result != true) return;

    if (mounted) {
      _showBlockingDialog('正在清空数据...');
    }

    try {
      await BackgroundService.stopService();
      await _databaseService.deleteAllRecords();
      await MapStateService.instance.clearAllMapStates();
      await NotificationService.instance.enableNotifications(true);
      await _databaseService.updateSettings(_collectSettings(reset: true));

      if (mounted) {
        Navigator.pop(context);
      }

      scaffoldMessenger.showSnackBar(const SnackBar(content: Text('数据已清空')));

      await _loadSettings();
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
      }
      scaffoldMessenger.showSnackBar(SnackBar(content: Text('清空错误：$e')));
    }
  }

  Widget _buildAboutSection() {
    return _buildSettingsCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              const Text('关于', style: AppTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 16),
          const Text('LBJ Console', style: AppTheme.titleMedium),
          const SizedBox(height: 8),
          FutureBuilder<String>(
            future: _getAppVersion(),
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                return Text(snapshot.data!, style: AppTheme.bodyMedium);
              } else {
                return const Text(
                  'v15.0.2-flutter',
                  style: AppTheme.bodyMedium,
                );
              }
            },
          ),
          const SizedBox(height: 8),
          Text('构建 hash：$appBuildHash', style: AppTheme.caption),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: widget.onCheckForUpdates,
            icon: const Icon(Icons.system_update),
            label: const Text('检查更新'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed:
                widget.onWirelessBrickRecovery == null &&
                    widget.onWiredBrickRecovery == null
                ? null
                : _openBrickRecoveryMode,
            icon: const Icon(Icons.build_circle_outlined),
            label: const Text('救砖模式'),
          ),
          SelectableText(
            '蓝牙诊断日志：${BleDiagnostics.logPath}',
            style: AppTheme.caption,
          ),
          if (widget.isBluetoothConnected) ...[
            const SizedBox(height: 8),
            Text(
              '当前固件：${widget.firmwareVersion ?? '未知（可尝试恢复升级）'}',
              style: AppTheme.caption,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: widget.onCheckFirmwareUpdate,
              icon: const Icon(Icons.memory),
              label: const Text('检查固件更新'),
            ),
          ],
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () async {
              final url = Uri.parse('https://github.com/undef-i/LBJConsole');
              if (await canLaunchUrl(url)) {
                await launchUrl(url);
              }
            },
            child: const Text(
              'https://github.com/undef-i/LBJConsole',
              style: AppTheme.caption,
            ),
          ),
        ],
      ),
    );
  }
}

/// Drive-letter picker for the CSV import. Scans A-Z for drives whose
/// `CSVTEST` folder contains at least one `.csv` and lists them as tappable
/// tiles; a manual-entry field covers drives the scan misses (a slow-to-report
/// drive, or a non-standard letter).
class _DrivePickerDialog extends StatefulWidget {
  const _DrivePickerDialog();

  @override
  State<_DrivePickerDialog> createState() => _DrivePickerDialogState();
}

class _DrivePickerDialogState extends State<_DrivePickerDialog> {
  final _manualController = TextEditingController();
  List<String> _drives = [];
  bool _scanning = true;

  @override
  void initState() {
    super.initState();
    _scanDrives();
  }

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  Future<void> _scanDrives() async {
    final found = <String>[];
    for (final letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) {
      final dir = Directory('$letter:\\CSVTEST');
      try {
        if (await dir.exists() && await _hasCsvFile(dir)) {
          found.add(letter);
        }
      } catch (_) {
        // Drive not ready / inaccessible (e.g. empty card slot) → skip.
      }
      if (!mounted) return;
    }
    if (mounted) {
      setState(() {
        _drives = found;
        _scanning = false;
      });
    }
  }

  Future<bool> _hasCsvFile(Directory dir) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.csv')) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择盘符'),
      content: SizedBox(
        width: double.maxFinite,
        child: _scanning
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('正在扫描盘符...'),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_drives.isEmpty)
                    const Text('未发现含 CSVTEST 文件夹的盘符，可手动输入盘符：')
                  else
                    ..._drives.map(
                      (d) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.usb),
                        title: Text('$d 盘'),
                        subtitle: Text('$d:\\CSVTEST'),
                        onTap: () => Navigator.pop(context, d),
                      ),
                    ),
                  const Divider(),
                  const Text('手动输入盘符：'),
                  TextField(
                    controller: _manualController,
                    decoration: const InputDecoration(hintText: '例如 A'),
                    maxLength: 1,
                    textCapitalization: TextCapitalization.characters,
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            final v = _manualController.text.trim().toUpperCase();
            Navigator.pop(context, v.isEmpty ? null : v);
          },
          child: const Text('导入'),
        ),
      ],
    );
  }
}
