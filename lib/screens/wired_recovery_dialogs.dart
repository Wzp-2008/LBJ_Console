import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:lbjconsole/services/wired_recovery_service.dart';

Future<void> showWiredRecoveryWorkflow(
  BuildContext context, {
  required WiredRecoveryService service,
  Future<void> Function(bool active)? onCriticalOperation,
}) async {
  if (!context.mounted || !Platform.isWindows) return;

  final device = await showDialog<EspflashDevice>(
    context: context,
    builder: (_) => _WiredDevicePickerDialog(service: service),
  );
  if (device == null || !context.mounted) return;

  WiredFirmwareBundle? bundle;
  while (bundle == null && context.mounted) {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        allowMultiple: false,
        withData: false,
        dialogTitle: '选择 ESP32 固件 ZIP',
      );
    } catch (error) {
      if (!context.mounted) return;
      await _showWiredMessage(context, '打开文件选择器失败：$error');
      continue;
    }
    if (picked == null) return;
    if (!context.mounted) return;
    final path = picked.files.single.path;
    if (path == null) {
      await _showWiredMessage(context, '无法读取所选文件路径，请重新选择。');
      continue;
    }
    try {
      bundle = await service.loadFirmwareZip(File(path));
    } catch (error) {
      if (!context.mounted) return;
      await _showWiredMessage(context, '固件包校验失败：$error');
    }
  }
  if (bundle == null) return;
  if (!context.mounted) {
    await bundle.dispose();
    return;
  }

  final baud = await showDialog<int>(
    context: context,
    builder: (_) => _WiredConfirmationDialog(device: device, bundle: bundle!),
  );
  if (baud == null || !context.mounted) {
    await bundle.dispose();
    return;
  }

  // Keep a separate last-chance confirmation immediately before any command
  // that can modify flash.  The parameter dialog above is intentionally
  // reviewable/back-navigable; this dialog is the destructive-action guard.
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('再次确认刷写'),
      content: Text(
        '即将使用 $baud 波特率刷写 ${device.port}。'
        '\n这会清除 bootctl 并覆盖 updater、firmware；请确认设备已连接且固件包正确。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('确认并开始'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) {
    await bundle.dispose();
    return;
  }

  var critical = false;
  try {
    // Mark the critical section before awaiting the tray update so an
    // exceptional UI/IPC update still runs the matching cleanup in finally.
    critical = true;
    await onCriticalOperation?.call(true);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WiredFlashProgressDialog(
        service: service,
        device: device,
        bundle: bundle!,
        baud: baud,
      ),
    );
  } finally {
    if (critical) await onCriticalOperation?.call(false);
    await bundle.dispose();
  }
}

Future<void> _showWiredMessage(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('有线救砖'),
      content: SelectableText(message),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

class _WiredDevicePickerDialog extends StatefulWidget {
  const _WiredDevicePickerDialog({required this.service});

  final WiredRecoveryService service;

  @override
  State<_WiredDevicePickerDialog> createState() =>
      _WiredDevicePickerDialogState();
}

class _WiredDevicePickerDialogState extends State<_WiredDevicePickerDialog> {
  List<EspflashDevice> _devices = const [];
  String? _error;
  String? _selectedPort;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  Future<void> _scan() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _selectedPort = null;
    });
    try {
      final devices = await widget.service.scanDevices();
      if (!mounted) return;
      setState(() => _devices = devices);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _devices = const [];
        _error = error.toString();
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    EspflashDevice? selected;
    for (final device in _devices) {
      if (device.port == _selectedPort) {
        selected = device;
        break;
      }
    }
    return AlertDialog(
      title: const Text('选择有线救砖设备'),
      content: SizedBox(
        width: 620,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_loading) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                _error ??
                    (_loading
                        ? '正在使用 espflash 扫描已识别的 ESP32 串口…'
                        : _devices.isEmpty
                        ? '未发现 espflash 可识别的 ESP32 串口。'
                        : '请选择要刷写的设备。'),
              ),
            ),
            Expanded(
              child: _devices.isEmpty
                  ? Center(
                      child: Icon(
                        _error == null ? Icons.usb_off : Icons.error_outline,
                        size: 52,
                        color: _error == null ? Colors.white38 : Colors.orange,
                      ),
                    )
                  : ListView.separated(
                      itemCount: _devices.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final device = _devices[index];
                        return ListTile(
                          selected: device.port == _selectedPort,
                          leading: const Icon(Icons.usb),
                          title: Text(device.port),
                          subtitle: Text(
                            device.details.isEmpty
                                ? 'espflash 已识别的串口'
                                : device.details,
                          ),
                          onTap: _loading
                              ? null
                              : () =>
                                    setState(() => _selectedPort = device.port),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : _scan,
          child: const Text('重新扫描'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: selected == null
              ? null
              : () => Navigator.pop(context, selected),
          icon: const Icon(Icons.arrow_forward),
          label: const Text('下一步'),
        ),
      ],
    );
  }
}

class _WiredConfirmationDialog extends StatefulWidget {
  const _WiredConfirmationDialog({required this.device, required this.bundle});

  final EspflashDevice device;
  final WiredFirmwareBundle bundle;

  @override
  State<_WiredConfirmationDialog> createState() =>
      _WiredConfirmationDialogState();
}

class _WiredConfirmationDialogState extends State<_WiredConfirmationDialog> {
  int _baud = WiredRecoveryService.supportedBaudRates.first;

  String _hex(int value) => '0x${value.toRadixString(16)}';

  String _size(int value) => '$value B';

  @override
  Widget build(BuildContext context) {
    final partitions = widget.bundle.partitions.values.toList()
      ..sort((a, b) => a.offset.compareTo(b.offset));
    return AlertDialog(
      title: const Text('确认有线救砖参数'),
      content: SizedBox(
        width: 650,
        height: 430,
        child: ListView(
          children: [
            Text('设备：${widget.device.port}'),
            if (widget.device.details.isNotEmpty)
              Text(
                widget.device.details,
                style: const TextStyle(color: Colors.white70),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _baud,
              decoration: const InputDecoration(labelText: '刷写波特率'),
              items: [
                for (final baud in WiredRecoveryService.supportedBaudRates)
                  DropdownMenuItem(value: baud, child: Text('$baud')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _baud = value);
              },
            ),
            const SizedBox(height: 16),
            const Text('固定区域：bootloader @ 0x1000；分区表 @ 0x10000（预留 0x1000）'),
            const SizedBox(height: 8),
            for (final name in const [
              'bootloader.bin',
              'updater.bin',
              'firmware.bin',
              'partitions.csv',
              'partitions.bin',
            ])
              Text(
                '$name：${_size(widget.bundle.file(name).lengthSync())}',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            const SizedBox(height: 8),
            for (final partition in partitions)
              Text(
                '${partition.name}: ${_hex(partition.offset)} / ${_size(partition.size)}',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            const SizedBox(height: 12),
            const Text('将清除 bootctl，保留 NVS 和 otadata。刷写期间不可取消、返回或退出程序。'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('返回'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, _baud),
          icon: const Icon(Icons.warning_amber),
          label: const Text('开始刷写'),
        ),
      ],
    );
  }
}

class _WiredFlashProgressDialog extends StatefulWidget {
  const _WiredFlashProgressDialog({
    required this.service,
    required this.device,
    required this.bundle,
    required this.baud,
  });

  final WiredRecoveryService service;
  final EspflashDevice device;
  final WiredFirmwareBundle bundle;
  final int baud;

  @override
  State<_WiredFlashProgressDialog> createState() =>
      _WiredFlashProgressDialogState();
}

class _WiredFlashProgressDialogState extends State<_WiredFlashProgressDialog> {
  WiredFlashStage? _stage;
  final List<String> _log = [];
  String? _error;
  bool _done = false;
  bool _success = false;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      await widget.service.flash(
        widget.device,
        widget.bundle,
        baud: widget.baud,
        onEvent: _onEvent,
      );
      if (!mounted) return;
      setState(() {
        _done = true;
        _success = true;
      });
    } catch (error) {
      if (!mounted) return;
      final message = error is WiredRecoveryException
          ? error.message
          : error.toString();
      final output = error is WiredRecoveryException ? error.output : '';
      setState(() {
        _done = true;
        _success = false;
        _error = message;
        if (output.trim().isNotEmpty) _log.add(output.trim());
      });
    }
  }

  void _onEvent(WiredFlashEvent event) {
    if (!mounted) return;
    setState(() {
      _stage = event.stage;
      if (event.output != null && event.output!.trim().isNotEmpty) {
        _log.add(event.output!.trim());
      }
    });
  }

  Future<void> _copyLog() async {
    final lines = <String>[];
    if (_error != null && _error!.trim().isNotEmpty) lines.add(_error!);
    lines.addAll(_log);
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final stages = WiredFlashStage.values;
    final stageIndex = _stage == null ? 0 : stages.indexOf(_stage!);
    final progress = _done ? 1.0 : (stageIndex + 0.15) / stages.length;
    return PopScope(
      canPop: _done,
      child: AlertDialog(
        title: Text(_done ? (_success ? '有线救砖完成' : '有线救砖失败') : '正在有线救砖'),
        content: SizedBox(
          width: 700,
          height: 470,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _done
                    ? (_success ? '所有分区已写入，设备已硬复位。' : _error ?? 'espflash 刷写失败')
                    : (_stage?.label ?? '准备中…'),
                style: TextStyle(color: _success ? Colors.greenAccent : null),
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: progress.clamp(0.0, 1.0)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < stages.length; i++)
                    Chip(
                      label: Text(stages[i].label),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: i < stageIndex || (_done && _success)
                          ? Colors.green.withValues(alpha: 0.25)
                          : i == stageIndex
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  color: Colors.black26,
                  child: _log.isEmpty
                      ? const Text('等待 espflash 输出…')
                      : ListView.builder(
                          itemCount: _log.length,
                          itemBuilder: (_, index) => SelectableText(
                            _log[index],
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (_done)
            TextButton.icon(
              onPressed: _copyLog,
              icon: const Icon(Icons.copy),
              label: Text(_copied ? '已复制' : '复制日志'),
            ),
          if (_done)
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
        ],
      ),
    );
  }
}
