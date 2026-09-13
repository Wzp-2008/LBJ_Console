import 'package:flutter_test/flutter_test.dart';
import 'package:lbjconsole/models/firmware_board.dart';

import 'helpers.dart';

void main() {
  setUp(() async {
    await initTestDb();
  });

  tearDown(() async {
    await disposeTestDatabase();
  });

  test('stores board history by normalized Bluetooth address', () async {
    final database = DatabaseService.instance;
    await database.setDeviceBoard('aa:bb:cc:dd:ee:ff', FirmwareBoard.lore32);

    expect(
      await database.getDeviceBoard('AA-BB-CC-DD-EE-FF'),
      FirmwareBoard.lore32,
    );
  });

  test('overwrites one address without affecting another', () async {
    final database = DatabaseService.instance;
    await database.setDeviceBoard('AA:BB:CC:DD:EE:01', FirmwareBoard.lore32);
    await database.setDeviceBoard('AA:BB:CC:DD:EE:02', FirmwareBoard.wzp);
    await database.setDeviceBoard('AA-BB-CC-DD-EE-01', FirmwareBoard.wzp);

    expect(
      await database.getDeviceBoard('AA:BB:CC:DD:EE:01'),
      FirmwareBoard.wzp,
    );
    expect(
      await database.getDeviceBoard('AA:BB:CC:DD:EE:02'),
      FirmwareBoard.wzp,
    );
  });

  test('clearDeviceBoardHistory removes saved mappings', () async {
    final database = DatabaseService.instance;
    await database.setDeviceBoard('AA:BB:CC:DD:EE:FF', FirmwareBoard.wzp);

    await database.clearDeviceBoardHistory();

    expect(await database.getDeviceBoard('AA:BB:CC:DD:EE:FF'), isNull);
  });
}
