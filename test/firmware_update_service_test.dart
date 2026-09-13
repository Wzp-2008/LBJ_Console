import 'package:flutter_test/flutter_test.dart';
import 'package:lbjconsole/services/file_share_api.dart';
import 'package:lbjconsole/services/firmware_ota_service.dart';

class _FakeFileShareApi extends FileShareApi {
  _FakeFileShareApi(this._page);

  final FileSharePage _page;

  @override
  Future<FileSharePage> listFiles({
    required int folder,
    int page = 1,
    int num = 10,
    String keywords = '',
    String sort = 'TIME',
    bool reverse = true,
  }) async {
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

      final update = await FirmwareOtaService(api: api).findLatestFirmware();
      expect(update?.version, '1234567890ABCDEF');
      expect(update?.fileId, 17);
      expect(update?.fileName, 'firmware-1234567890ABCDEF.bin');
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

    expect(await FirmwareOtaService(api: api).findLatestFirmware(), isNull);
  });
}
