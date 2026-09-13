import 'dart:io';

/// Shared streamed downloader for app and firmware updates.
class HttpDownload {
  static const connectionTimeout = Duration(seconds: 20);
  static const responseTimeout = Duration(seconds: 30);

  static Future<File> download(
    Uri url,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    final client = HttpClient()..connectionTimeout = connectionTimeout;
    try {
      final request = await client.getUrl(url).timeout(connectionTimeout);
      final response = await request.close().timeout(responseTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw HttpDownloadException(
          '下载失败（HTTP ${response.statusCode}）',
          response.statusCode,
        );
      }

      await destination.parent.create(recursive: true);
      final sink = destination.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(responseTimeout)) {
          sink.add(chunk);
          received += chunk.length;
          if (response.contentLength > 0) {
            onProgress?.call(received / response.contentLength);
          }
        }
        await sink.close();
      } catch (_) {
        await sink.close();
        rethrow;
      }
      onProgress?.call(1);
      return destination;
    } finally {
      client.close(force: true);
    }
  }
}

class HttpDownloadException implements Exception {
  const HttpDownloadException(this.message, [this.statusCode]);

  final String message;
  final int? statusCode;

  @override
  String toString() => 'HttpDownloadException: $message';
}
