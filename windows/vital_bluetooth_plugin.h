#ifndef FLUTTER_PLUGIN_VITAL_BLUETOOTH_PLUGIN_H_
#define FLUTTER_PLUGIN_VITAL_BLUETOOTH_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

#include "ble_host.h"
#include "classic_host.h"
#include "messages.g.h"

namespace vital_bluetooth {

// Registers the Pigeon host APIs with the Flutter engine and owns them.
class VitalBluetoothPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit VitalBluetoothPlugin(flutter::BinaryMessenger* messenger);

  virtual ~VitalBluetoothPlugin();

  // Disallow copy and assign.
  VitalBluetoothPlugin(const VitalBluetoothPlugin&) = delete;
  VitalBluetoothPlugin& operator=(const VitalBluetoothPlugin&) = delete;

 private:
  flutter::BinaryMessenger* messenger_;
  BleFlutterApi ble_events_;
  ClassicFlutterApi classic_events_;
  BleHost ble_;
  ClassicHost classic_;
};

}  // namespace vital_bluetooth

#endif  // FLUTTER_PLUGIN_VITAL_BLUETOOTH_PLUGIN_H_
