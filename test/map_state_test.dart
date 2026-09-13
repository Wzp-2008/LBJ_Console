import 'package:flutter_test/flutter_test.dart';
import 'package:lbjconsole/models/map_state.dart';
import 'package:lbjconsole/services/map_state_service.dart';

import 'helpers.dart';

void main() {
  late MapStateService service;

  setUpAll(() async {
    await initTestDb();
    service = MapStateService.instance;
    await service.clearAllMapStates();
  });

  setUp(() async {
    await service.clearAllMapStates();
  });

  tearDownAll(() async {
    await service.clearAllMapStates();
    await disposeTestDatabase();
  });

  test('saves, reads and deletes a map state', () async {
    const key = 'record-1_record_map';
    final state = MapState(
      zoom: 12.5,
      centerLat: 30.2,
      centerLng: 120.1,
      bearing: 45,
    );

    await service.saveMapState(key, state);
    final loaded = await service.getMapState(key);
    expect(loaded?.zoom, 12.5);
    expect(loaded?.centerLat, 30.2);
    expect(loaded?.centerLng, 120.1);
    expect(loaded?.bearing, 45);

    await service.deleteMapState(key);
    expect(await service.getMapState(key), isNull);
  });

  test('debounced writes keep only the newest state', () async {
    const key = 'group-1_group_map';
    service.saveMapStateDebounced(
      key,
      MapState(zoom: 8, centerLat: 1, centerLng: 2, bearing: 3),
    );
    service.saveMapStateDebounced(
      key,
      MapState(zoom: 9, centerLat: 4, centerLng: 5, bearing: 6),
    );

    await Future<void>.delayed(const Duration(milliseconds: 400));
    final loaded = await service.getMapState(key);
    expect(loaded?.zoom, 9);
    expect(loaded?.centerLat, 4);
    expect(loaded?.centerLng, 5);
    expect(loaded?.bearing, 6);
  });

  test('record deletion removes its persisted map state', () async {
    const recordId = 'record-to-delete';
    final key = service.getSingleRecordMapKey(recordId);
    await DatabaseService.instance.insertRecord(
      mkRecord(uniqueId: recordId, receivedMs: 1700000000000, train: 'T1'),
    );
    await service.saveMapState(
      key,
      MapState(zoom: 10, centerLat: 30, centerLng: 120, bearing: 0),
    );

    await DatabaseService.instance.deleteRecord(recordId);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await service.getMapState(key), isNull);
  });
}
