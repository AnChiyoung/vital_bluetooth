#include "include/vital_bluetooth/vital_bluetooth_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "vital_bluetooth_plugin.h"

void VitalBluetoothPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  vital_bluetooth::VitalBluetoothPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
