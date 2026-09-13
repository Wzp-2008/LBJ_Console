import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lbjconsole/screens/main_screen.dart';
import 'package:lbjconsole/services/classic_spp_service.dart';

class _FakeDiscoverySession extends ClassicSppDiscoverySession {
  _FakeDiscoverySession(this.devices);

  final List<ClassicBluetoothDevice> devices;
  final _controller =
      StreamController<List<ClassicBluetoothDevice>>.broadcast();

  @override
  Stream<List<ClassicBluetoothDevice>> get updates => _controller.stream;

  @override
  bool get isScanning => false;

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 16)}) async {
    await Future<void>.delayed(Duration.zero);
    _controller.add(devices);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => _controller.close();
}

ClassicBluetoothDevice _device(
  String address,
  String name, {
  int? classOfDevice,
  bool paired = false,
}) => ClassicBluetoothDevice(
  device: BtcDevice(
    address: address,
    name: name,
    classOfDevice: classOfDevice,
    bondState: paired ? BtcBondState.bonded : BtcBondState.none,
  ),
  isPaired: paired,
);

Widget _appWith(List<ClassicBluetoothDevice> devices) => MaterialApp(
  home: Scaffold(
    body: RescueDevicePickerDialog(discovery: _FakeDiscoverySession(devices)),
  ),
);

void main() {
  testWidgets('defaults to CoD matches and can reveal all devices', (
    tester,
  ) async {
    await tester.pumpWidget(
      _appWith([
        _device(
          'AA:BB:CC:DD:EE:01',
          'Updater',
          classOfDevice: 0x801FFC,
          paired: true,
        ),
        _device('AA:BB:CC:DD:EE:02', 'Other device', classOfDevice: 0x801FF8),
        _device('AA:BB:CC:DD:EE:03', 'Legacy device'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Updater'), findsOneWidget);
    expect(find.textContaining('救砖设备 · CoD 0x801FFC'), findsOneWidget);
    expect(find.text('Other device'), findsNothing);
    expect(find.text('Legacy device'), findsNothing);

    await tester.tap(find.text('显示全部设备'));
    await tester.pumpAndSettle();

    expect(find.text('Other device'), findsOneWidget);
    expect(find.text('Legacy device'), findsOneWidget);
    expect(find.textContaining('CoD 未知'), findsOneWidget);
  });

  testWidgets('shows the empty state when no recovery CoD matches', (
    tester,
  ) async {
    await tester.pumpWidget(
      _appWith([_device('AA:BB:CC:DD:EE:02', 'Other device')]),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('1 台蓝牙设备，但没有匹配 CoD 0x801FFC'), findsOneWidget);
    expect(find.text('显示全部设备'), findsOneWidget);
    expect(find.text('Other device'), findsNothing);
  });

  testWidgets('a fresh picker restores the default CoD filter', (tester) async {
    final devices = [_device('AA:BB:CC:DD:EE:02', 'Other device')];
    await tester.pumpWidget(_appWith(devices));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示全部设备'));
    await tester.pumpAndSettle();
    expect(find.text('Other device'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(_appWith(devices));
    await tester.pumpAndSettle();

    expect(find.text('Other device'), findsNothing);
    expect(find.text('显示全部设备'), findsOneWidget);
  });
}
