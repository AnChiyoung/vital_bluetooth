#include "vital_bluetooth_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <memory>

namespace vital_bluetooth {

// static
void VitalBluetoothPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(
      std::make_unique<VitalBluetoothPlugin>(registrar->messenger()));
}

VitalBluetoothPlugin::VitalBluetoothPlugin(flutter::BinaryMessenger* messenger)
    : messenger_(messenger),
      ble_events_(messenger),
      classic_events_(messenger),
      ble_(&ble_events_, std::make_shared<UiThread>()),
      classic_(&classic_events_) {
  BleHostApi::SetUp(messenger_, &ble_);
  ClassicHostApi::SetUp(messenger_, &classic_);
}

VitalBluetoothPlugin::~VitalBluetoothPlugin() {
  BleHostApi::SetUp(messenger_, nullptr);
  ClassicHostApi::SetUp(messenger_, nullptr);
}

}  // namespace vital_bluetooth
