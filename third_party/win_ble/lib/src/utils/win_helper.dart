/// This class is used to store the device map and subscription map
/// and some other helper methods
class WinHelper {
  static final Map<String, String> deviceMap = {};
  static final Map<String, Map<String, String>> subscriptions = {};
  static bool showLog = false;

  /// enableLog in [initialize] method
  static void printLog(Object? log) {
    // ignore: avoid_print
    if (showLog) print(log);
  }

  static String toWindowsUuid(String uuid) => "{$uuid}";

  static String fromWindowsUuid(String uuid) =>
      uuid.replaceAll("{", "").replaceAll("}", "");

  static String getDeviceFromAddress(String address) {
    return deviceMap[address] ??
        (throw StateError('Device not found: $address'));
  }

  static String? getAddressFromDevice(String device) {
    for (final entry in deviceMap.entries) {
      if (entry.value == device) return entry.key;
    }
    return null;
  }

  static Map<String, String>? getDataFromSubscriptionKey(
      String subscriptionKey) {
    return subscriptions[subscriptionKey];
  }
}
