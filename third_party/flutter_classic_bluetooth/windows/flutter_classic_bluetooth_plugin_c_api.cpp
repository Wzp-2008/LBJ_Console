#include "include/flutter_classic_bluetooth/flutter_classic_bluetooth_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_classic_bluetooth_plugin.h"

void FlutterClassicBluetoothPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_classic_bluetooth::FlutterClassicBluetoothPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
