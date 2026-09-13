#include <flutter_linux/flutter_linux.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "include/flutter_classic_bluetooth/flutter_classic_bluetooth_plugin.h"

namespace flutter_classic_bluetooth {
namespace test {

TEST(FlutterClassicBluetoothPlugin, PluginRegisters) {
  // Basic test to verify the plugin type can be instantiated
  EXPECT_NE(flutter_classic_bluetooth_plugin_get_type(), 0u);
}

}  // namespace test
}  // namespace flutter_classic_bluetooth
