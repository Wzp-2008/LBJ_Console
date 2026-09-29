import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:lbjconsole/models/map_state.dart';
import 'package:lbjconsole/services/map_state_service.dart';
import 'package:lbjconsole/screens/history_screen.dart';
import 'helpers.dart';

class FakeLocation extends GeolocatorPlatform {
  int checks = 0;
  int starts = 0;
  int stops = 0;
  bool granted = false;
  final permissionRequest = Completer<LocationPermission>();
  @override
  Future<bool> isLocationServiceEnabled() async {
    checks++;
    return true;
  }

  @override
  Future<LocationPermission> checkPermission() async =>
      granted ? LocationPermission.whileInUse : LocationPermission.denied;
  @override
  Future<LocationPermission> requestPermission() async {
    final result = await permissionRequest.future;
    granted = result == LocationPermission.whileInUse;
    return result;
  }

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    expect(locationSettings?.accuracy, LocationAccuracy.medium);
    expect(locationSettings?.distanceFilter, 25);
    return StreamController<Position>(
      onListen: () => starts++,
      onCancel: () => stops++,
    ).stream;
  }
}

void main() {
  testWidgets(
    'maps locate only while expanded and foreground; live merges keep expansion',
    (tester) async {
      final originalLocation = GeolocatorPlatform.instance;
      final location = FakeLocation();
      final cacheDirectory = Directory.systemTemp.createTempSync(
        'lbj_history_test_',
      );
      final tileCache = BuiltInMapCachingProvider.getOrCreateInstance(
        cacheDirectory: cacheDirectory.path,
        maxCacheSize: null,
        readOnly: true,
      );
      GeolocatorPlatform.instance = location;
      final key = GlobalKey<HistoryScreenState>();
      var active = true;
      Widget screen() => MaterialApp(
        home: Scaffold(
          body: HistoryScreen(
            key: key,
            active: active,
            onEditModeChanged: (_) {},
            onSelectionChanged: () {},
          ),
        ),
      );
      final first = mkRecord(
        uniqueId: 'a',
        receivedMs: 1700000000000,
        train: 'T1',
        positionInfo: '30°10.0′ 120°10.0′',
        direction: 1,
      );
      await tester.runAsync(() async {
        await initTestDb();
        await DatabaseService.instance.updateSettings({
          'mergeRecordsEnabled': 1,
        });
        await DatabaseService.instance.insertRecord(first);
        await MapStateService.instance.saveMapState(
          'a_record_map',
          MapState(zoom: 12, centerLat: 30, centerLng: 120, bearing: 10),
        );
      });
      // Pump real database completions without waiting on map tile networking.
      Future<void> drain() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }

      try {
        await tester.pumpWidget(screen());
        await drain();
        await drain();
        expect(
          location.checks,
          0,
          reason: 'Collapsed home must not activate GPS',
        );
        await tester.tap(find.byKey(const ValueKey('a')).first);
        await tester.pump();
        await drain();
        expect(location.starts, 0);
        // Android permission UI briefly deactivates the application.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        location.permissionRequest.complete(LocationPermission.whileInUse);
        await drain();
        await drain();
        expect(location.starts, 1);
        final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
        expect(map.options.initialZoom, 12);
        expect(map.options.initialRotation, 10);
        final next = mkRecord(
          uniqueId: 'b',
          receivedMs: 1700000010000,
          train: 'T1',
          positionInfo: first.positionInfo,
          direction: 1,
        );
        await tester.runAsync(() async {
          await DatabaseService.instance.insertRecord(next);
          await key.currentState!.addNewRecord(next);
        });
        await tester.pump();
        await drain();
        await drain();
        expect(find.text('共 2 条 · 点击展开'), findsOneWidget);
        expect(
          location.starts,
          1,
          reason: 'Live singleton-to-group transition stays expanded',
        );
        active = false;
        await tester.pumpWidget(screen());
        await drain();
        expect(location.stops, 1, reason: 'Settings page must stop location');
        active = true;
        await tester.pumpWidget(screen());
        await drain();
        expect(location.starts, 2);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await drain();
        expect(location.stops, 2);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await drain();
        expect(location.starts, 3);
        // Collapse the merged card, which has an outer identity key m:a.
        await tester.tap(find.text('共 2 条 · 点击展开'));
        await tester.pump();
        await drain();
        expect(location.stops, 3);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(disposeTestDatabase);
        var cacheDestroyed = false;
        unawaited(tileCache.destroy().then((_) => cacheDestroyed = true));
        for (var i = 0; i < 30 && !cacheDestroyed; i++) {
          await drain();
        }
        expect(cacheDestroyed, isTrue);
        await tester.runAsync(() => cacheDirectory.delete(recursive: true));
        GeolocatorPlatform.instance = originalLocation;
      }
    },
  );
}
