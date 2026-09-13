import 'package:flutter_test/flutter_test.dart';
import 'package:lbjconsole/services/file_share_api.dart';
import 'package:lbjconsole/services/firmware_ota_service.dart';
import 'package:lbjconsole/models/firmware_board.dart';

class _FakeFileShareApi extends FileShareApi {
  _FakeFileShareApi(this._page);

  final FileSharePage _page;
  final List<int> requestedFolders = [];

  @override
  Future<FileSharePage> listFiles({
    required int folder,
    int page = 1,
    int num = 10,
    String keywords = '',
    String sort = 'TIME',
    bool reverse = true,
  }) async {
    requestedFolders.add(folder);
    return _page;
  }
}

void main() {
  test(
    'findLatestFirmware ignores malformed entries and normalizes version',
    () async {
      final api = _FakeFileShareApi(
        const FileSharePage(
          files: [
            {'name': 'firmware-not-a-version', 'ext': 'bin', 'id': 1},
            {'name': 'firmware-1234567890ABCDEF', 'ext': '.BIN', 'id': '17'},
          ],
          total: 2,
        ),
      );
      addTearDown(api.close);

      final update = await FirmwareOtaService(
        api: api,
      ).findLatestFirmware(FirmwareBoard.lore32);
      expect(update?.version, '1234567890ABCDEF');
      expect(update?.fileId, 17);
      expect(update?.fileName, 'firmware-1234567890ABCDEF.bin');
      expect(update?.board, FirmwareBoard.lore32);
      expect(api.requestedFolders, [3471]);
    },
  );

  test('returns null when no valid firmware entry exists', () async {
    final api = _FakeFileShareApi(
      const FileSharePage(
        files: [
          {'name': 'firmware-1234', 'ext': 'bin', 'id': 1},
          {'name': 'firmware-1234567890abcdef', 'ext': 'zip', 'id': 2},
          {'name': 'other-1234567890abcdef', 'ext': 'bin', 'id': 3},
        ],
        total: 3,
      ),
    );
    addTearDown(api.close);

    expect(
      await FirmwareOtaService(api: api).findLatestFirmware(FirmwareBoard.wzp),
      isNull,
    );
    expect(api.requestedFolders, [3472]);
  });

  test('board parser and recovery CoD use the protocol constants', () {
    expect(FirmwareBoard.fromWireValue(' WZP '), FirmwareBoard.wzp);
    expect(FirmwareBoard.fromWireValue('Lore32'), FirmwareBoard.lore32);
    expect(FirmwareBoard.fromWireValue('other'), isNull);
    expect(isRecoveryClassOfDevice(0x801FFC), isTrue);
    expect(
      composeClassOfDevice(service: 0x400, major: 0x1F, minor: 0x3F),
      0x801FFC,
    );
    expect(isRecoveryClassOfDevice(0x801BFC), isFalse);
    expect(isRecoveryClassOfDevice(0x801FF8), isFalse);
    expect(isRecoveryClassOfDevice(0x401FFC), isFalse);
    expect(isRecoveryClassOfDevice(0xAB801FFC), isTrue);
    expect(isRecoveryClassOfDevice(null), isFalse);
  });
}
