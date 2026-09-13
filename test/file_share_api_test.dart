import 'package:flutter_test/flutter_test.dart';
import 'package:lbjconsole/services/file_share_api.dart';

void main() {
  test('file metadata helpers accept the server field aliases', () {
    final item = {
      'filename': 'LBJ-Console-ab12cd34',
      'extension': '.APK',
      'fileId': '42',
      'createdAt': '2026-09-13T00:00:00Z',
    };

    expect(fileShareFileName(item), 'LBJ-Console-ab12cd34');
    expect(fileShareExtension(item), 'apk');
    expect(fileShareId(item), 42);
    expect(fileShareUploadTime(item), '2026-09-13T00:00:00Z');
  });

  test('metadata helpers reject missing or malformed IDs', () {
    expect(fileShareFileName(const {}), isEmpty);
    expect(fileShareExtension({'name': 'update'}), isEmpty);
    expect(fileShareId({'id': 'not-a-number'}), isNull);
    expect(fileShareUploadTime(const {}), isNull);
  });

  test('listFiles validates pagination before making a request', () async {
    final api = FileShareApi();
    addTearDown(api.close);

    await expectLater(api.listFiles(folder: -1), throwsA(isA<ArgumentError>()));
    await expectLater(
      api.listFiles(folder: 1, page: 0),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      api.listFiles(folder: 1, num: 0),
      throwsA(isA<ArgumentError>()),
    );
  });
}
