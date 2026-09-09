import 'dart:convert';
import 'dart:io';

/// 文件分享站 API。
///
/// 接口不需要鉴权，也不需要模拟浏览器请求头。
class FileShareApi {
  FileShareApi({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  static const String _baseUrl = 'https://wzpmc.cn:83';

  final HttpClient _httpClient;

  /// 列出文件夹中的文件。
  ///
  /// [folder] 为文件夹 ID；[page] 从 1 开始。
  /// 服务端返回的文件对象会完整保存在 [FileSharePage.files] 中。
  Future<FileSharePage> listFiles({
    required int folder,
    int page = 1,
    int num = 10,
    String keywords = '',
    String sort = 'TIME',
    bool reverse = true,
  }) async {
    if (folder < 0) {
      throw ArgumentError.value(folder, 'folder', '文件夹 ID 不能小于 0');
    }
    if (page < 1) {
      throw ArgumentError.value(page, 'page', '页数必须从 1 开始');
    }
    if (num < 1) {
      throw ArgumentError.value(num, 'num', '每页项目数必须大于 0');
    }

    final uri = Uri.parse('$_baseUrl/api/file/get').replace(
      queryParameters: {
        'num': '$num',
        'page': '$page',
        'folder': '$folder',
        'keywords': keywords,
        'sort': sort,
        'reverse': '$reverse',
      },
    );

    final body = await _getJson(uri);
    final data = _asMap(body['data'], 'data');
    final files = data['data'];
    if (files is! List) {
      throw FileShareApiException('列表接口返回的 data.data 不是数组');
    }

    return FileSharePage(
      files: files
          .map((item) {
            if (item is! Map) {
              throw FileShareApiException('列表接口返回了格式错误的文件项');
            }
            return Map<String, dynamic>.from(item);
          })
          .toList(growable: false),
      total: _asInt(data['total'], 'data.total'),
    );
  }

  /// 根据文件 ID 获取可下载的完整 URL。
  Future<Uri> getDownloadUrl({required int fileId}) async {
    final uri = Uri.parse(
      '$_baseUrl/api/file/link',
    ).replace(queryParameters: {'id': '$fileId'});
    final body = await _getJson(uri);
    final code = body['data'];
    if (code is! String || code.isEmpty) {
      throw FileShareApiException('下载链接接口没有返回有效链接标识');
    }
    return Uri.parse('$_baseUrl/api/file/download/$code');
  }

  /// 下载 [downloadUrl] 指向的文件并保存到 [savePath]，返回保存后的文件。
  ///
  /// 下载使用流式写入，不会把整个文件一次性读入内存。目标文件已存在时会覆盖。
  Future<File> downloadFile({
    required Uri downloadUrl,
    required String savePath,
  }) async {
    final request = await _httpClient.getUrl(downloadUrl);
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = await utf8.decoder.bind(response).join();
      throw FileShareApiException(
        '文件下载失败（HTTP ${response.statusCode}）${message.isEmpty ? '' : ': $message'}',
        statusCode: response.statusCode,
      );
    }

    final file = File(savePath);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    try {
      await response.pipe(sink);
    } catch (_) {
      await sink.close();
      rethrow;
    }
    return file;
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final request = await _httpClient.getUrl(uri);
    final response = await request.close();
    final responseBody = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FileShareApiException(
        '请求失败（HTTP ${response.statusCode}）${responseBody.isEmpty ? '' : ': $responseBody'}',
        statusCode: response.statusCode,
      );
    }

    final decoded = jsonDecode(responseBody);
    if (decoded is! Map) {
      throw FileShareApiException('接口返回的 JSON 不是对象');
    }
    final body = Map<String, dynamic>.from(decoded);
    final apiStatus = body['status'];
    if (apiStatus is num && apiStatus < 200 ||
        apiStatus is num && apiStatus >= 300) {
      throw FileShareApiException(
        body['msg']?.toString() ?? '文件分享站接口返回错误',
        statusCode: apiStatus.toInt(),
      );
    }
    return body;
  }

  Map<String, dynamic> _asMap(Object? value, String field) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw FileShareApiException('接口返回的 $field 不是对象');
  }

  int _asInt(Object? value, String field) {
    if (value is num) return value.toInt();
    throw FileShareApiException('接口返回的 $field 不是数字');
  }

  void close() => _httpClient.close(force: true);
}

class FileSharePage {
  const FileSharePage({required this.files, required this.total});

  final List<Map<String, dynamic>> files;
  final int total;
}

class FileShareApiException implements Exception {
  const FileShareApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'FileShareApiException: $message';
}
