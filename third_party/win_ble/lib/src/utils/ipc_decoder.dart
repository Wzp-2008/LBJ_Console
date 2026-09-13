import 'dart:convert';
import 'dart:typed_data';

class IpcDecoder {
  final List<int> _buffer = [];
  List<dynamic> add(List<int> bytes) {
    _buffer.addAll(bytes);
    final messages = <dynamic>[];
    var cursor = 0;
    while (_buffer.length - cursor >= 4) {
      final header = Uint8List.fromList(_buffer.sublist(cursor, cursor + 4));
      final length = ByteData.sublistView(header).getUint32(0, Endian.little);
      if (length > 16 * 1024 * 1024) {
        _buffer.clear();
        throw const FormatException('BLE IPC frame exceeds 16 MiB');
      }
      if (_buffer.length - cursor - 4 < length) break;
      final payloadStart = cursor + 4;
      final payloadEnd = payloadStart + length;
      // Consume the complete frame before decoding it. A malformed JSON
      // payload must be dropped without poisoning all following frames.
      cursor = payloadEnd;
      try {
        messages.add(jsonDecode(utf8.decode(
          _buffer.sublist(payloadStart, payloadEnd),
        )));
      } on FormatException {
        // Ignore one malformed frame and continue with the next complete one.
      }
    }
    _buffer.removeRange(0, cursor);
    return messages;
  }
}
