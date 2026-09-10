import 'dart:convert';
import 'dart:typed_data';

bool shouldReconnectBle({
  required String? savedAddress,
  required bool adapterOn,
  required bool connected,
  required bool connecting,
  required bool manuallyDisconnected,
  required bool blocked,
  required bool otaActive,
}) =>
    savedAddress != null &&
    savedAddress.isNotEmpty &&
    adapterOn &&
    !connected &&
    !connecting &&
    !manuallyDisconnected &&
    !blocked &&
    !otaActive;

/// Frame on bytes, not decoded fragments: a notification can split UTF-8.
class BleJsonDecoder {
  final List<int> _buffer = [];
  int _depth = 0;
  bool _quoted = false;
  bool _escaped = false;

  void clear() {
    _buffer.clear();
    _depth = 0;
    _quoted = false;
    _escaped = false;
  }

  List<Map<String, dynamic>> add(List<int> bytes) {
    final result = <Map<String, dynamic>>[];
    for (final byte in bytes) {
      if (_buffer.isEmpty && byte != 123) continue;
      _buffer.add(byte);
      if (_quoted) {
        if (_escaped) {
          _escaped = false;
        } else if (byte == 92) {
          _escaped = true;
        } else if (byte == 34) {
          _quoted = false;
        }
      } else if (byte == 34) {
        _quoted = true;
      } else if (byte == 123) {
        _depth++;
      } else if (byte == 125) {
        _depth--;
      }
      if (_depth == 0) {
        final frame = List<int>.of(_buffer);
        clear();
        // A malformed object must not discard valid objects already decoded
        // in this batch or prevent later objects from being considered.
        try {
          final decoded = jsonDecode(utf8.decode(frame));
          if (decoded is Map) {
            result.add(Map<String, dynamic>.from(decoded));
          }
        } on FormatException {
          // Drop this complete frame and continue with the next one.
        } on TypeError {
          // A syntactically valid JSON value which is not an object is not a
          // BLE message, but it is still isolated to this frame.
        }
      } else if (_buffer.length > 65536) {
        clear();
        throw const FormatException('BLE JSON exceeds 64 KiB');
      }
    }
    return result;
  }
}

Uint8List otaCrcFrame(List<int> payload) {
  var crc = 0xffffffff;
  for (final byte in payload) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
    }
  }
  final frame = Uint8List(payload.length + 8);
  frame.setRange(0, 4, const [79, 84, 65, 68]);
  ByteData.sublistView(frame).setUint32(4, crc ^ 0xffffffff, Endian.little);
  frame.setRange(8, frame.length, payload);
  return frame;
}

/// Classic SPP is a byte stream, so every firmware frame carries its length.
const maxOtaSppPayload = 4096;

Uint8List otaSppFrame(List<int> payload) {
  if (payload.isEmpty || payload.length > maxOtaSppPayload) {
    throw ArgumentError.value(
      payload.length,
      'payload',
      'SPP payload 必须为 1..4096 字节',
    );
  }
  final crcFrame = otaCrcFrame(payload);
  final frame = Uint8List(payload.length + 12);
  frame.setRange(0, 4, const [79, 84, 65, 68]);
  final header = ByteData.sublistView(frame);
  header.setUint32(4, payload.length, Endian.little);
  header.setUint32(
    8,
    ByteData.sublistView(crcFrame).getUint32(4, Endian.little),
    Endian.little,
  );
  frame.setRange(12, frame.length, payload);
  return frame;
}

class SppLineDecoder {
  final List<int> _buffer = [];

  List<String> add(List<int> bytes) {
    final lines = <String>[];
    for (final byte in bytes) {
      if (byte == 10) {
        if (_buffer.isNotEmpty && _buffer.last == 13) _buffer.removeLast();
        final lineBytes = List<int>.of(_buffer);
        _buffer.clear();
        try {
          lines.add(utf8.decode(lineBytes));
        } on FormatException {
          // An invalid status line is independent of the following line.
          // Clearing before decoding prevents its bytes from poisoning the
          // next fragmented message.
        }
      } else {
        _buffer.add(byte);
        if (_buffer.length > 65536) {
          _buffer.clear();
          throw const FormatException('SPP 状态行超过 64 KiB');
        }
      }
    }
    return lines;
  }
}

String otaStateLabel(String state) =>
    const {
      'downloading': '正在下载固件',
      'starting': '请求进入升级模式',
      'switching': '等待设备重启进入 Updater',
      'reconnecting': '正在连接 Classic SPP',
      'receiving': '正在传输固件',
      'ack': '数据块已确认',
      'verifying': '正在校验固件',
      'success': '升级成功，设备正在重启',
      'error': '升级失败',
      'aborted': '升级已取消',
    }[state] ??
    state;

String otaErrorLabel(String code) =>
    const {
      'invalid_size': '固件大小无效',
      'invalid_command': '设备无法解析升级命令',
      'invalid_data_frame': 'SPP 固件数据帧长度无效',
      'queue_full': 'Updater 接收队列已满',
      'invalid_sha256': 'SHA-256 格式无效',
      'already_active': '设备已有升级会话，请断开重连后重试',
      'not_receiving': '设备未进入固件接收状态',
      'size_mismatch': '设备接收的固件大小不一致',
      'crc_mismatch': '数据包 CRC32 校验失败',
      'sha256_mismatch': '固件 SHA-256 校验失败',
      'ota_begin_failed': '设备无法打开 OTA 分区',
      'ota_write_failed': '设备写入固件失败',
      'ota_finalize_failed': '固件镜像校验或提交失败',
      'disconnected': '传输中蓝牙断开，请重连后从头升级',
      'cancelled': '升级已取消',
    }[code] ??
    '设备报告升级错误：$code';
