#include <winsock2.h>
#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>

#include "flutter_classic_bluetooth_plugin.h"

namespace flutter_classic_bluetooth {
namespace test {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

TEST(FlutterClassicBluetoothPlugin, IsSupported) {
  FlutterClassicBluetoothPlugin plugin(nullptr);
  bool success_called = false;
  plugin.HandleMethodCall(
      MethodCall("isSupported", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&success_called](const EncodableValue* result) {
            success_called = true;
            EXPECT_TRUE(std::holds_alternative<bool>(*result));
          },
          nullptr, nullptr));

  EXPECT_TRUE(success_called);
}

TEST(FlutterClassicBluetoothPlugin, GetPlatformCapabilities) {
  FlutterClassicBluetoothPlugin plugin(nullptr);
  bool success_called = false;
  plugin.HandleMethodCall(
      MethodCall("getPlatformCapabilities", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&success_called](const EncodableValue* result) {
            success_called = true;
            EXPECT_TRUE(std::holds_alternative<EncodableMap>(*result));
            auto& map = std::get<EncodableMap>(*result);
            // should contain canDiscoverDevices
            auto it = map.find(EncodableValue("canDiscoverDevices"));
            EXPECT_NE(it, map.end());
          },
          nullptr, nullptr));

  EXPECT_TRUE(success_called);
}

TEST(FlutterClassicBluetoothPlugin, UnknownMethodNotImplemented) {
  FlutterClassicBluetoothPlugin plugin(nullptr);
  bool not_implemented = false;
  plugin.HandleMethodCall(
      MethodCall("nonExistentMethod", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          nullptr, nullptr,
          [&not_implemented]() {
            not_implemented = true;
          }));

  EXPECT_TRUE(not_implemented);
}

}  // namespace test
}  // namespace flutter_classic_bluetooth
