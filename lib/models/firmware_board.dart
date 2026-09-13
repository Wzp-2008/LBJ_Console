enum FirmwareBoard {
  lore32('lore32', 'lore32', 3471),
  wzp('wzp', 'wzp', 3472);

  const FirmwareBoard(this.wireName, this.displayName, this.folderId);

  final String wireName;
  final String displayName;
  final int folderId;

  static FirmwareBoard? fromWireValue(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final board in values) {
      if (board.wireName == normalized) return board;
    }
    return null;
  }
}

const firmwareBoardWarning =
    '若选择错误的板子并刷入固件，造成了板子无法点亮的情况，'
    '请使用设置页面最下方的救砖模式进行救砖';

const recoveryClassOfDevice = 0x801FFC;

int composeClassOfDevice({
  required int service,
  required int major,
  required int minor,
}) => ((service & 0x7FF) << 13) | ((major & 0x1F) << 8) | ((minor & 0x3F) << 2);

bool isRecoveryClassOfDevice(int? value) =>
    value != null && (value & 0xFFFFFF) == recoveryClassOfDevice;

String formatClassOfDevice(int value) =>
    '0x${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

String normalizeBluetoothAddress(String address) {
  final trimmed = address.trim().toUpperCase();
  final compact = trimmed.replaceAll(RegExp(r'[:-]'), '');
  return RegExp(r'^[0-9A-F]{12}$').hasMatch(compact) ? compact : trimmed;
}
