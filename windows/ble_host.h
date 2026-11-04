#ifndef FLUTTER_PLUGIN_VITAL_BLUETOOTH_BLE_HOST_H_
#define FLUTTER_PLUGIN_VITAL_BLUETOOTH_BLE_HOST_H_

#include <windows.h>

#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Foundation.h>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "messages.g.h"
#include "ui_thread.h"

namespace vital_bluetooth {

// Windows side of BleHostApi, on WinRT Windows.Devices.Bluetooth.
//
// All state lives on the UI thread. WinRT work runs in coroutines that
// return to the UI thread (ResumeOnUi) after every co_await, and WinRT
// events are posted there before they touch anything.
//
// Windows connects when GATT is first used, so connect() opens a
// GattSession with MaintainConnection on and reads the services. While the
// session is open Windows also restores a dropped link by itself, which is
// why a disconnect(forget: false) between Dart's reconnect attempts keeps
// it open.
//
// Instance numbers are Windows' attribute handles, which are unique.
class BleHost : public BleHostApi {
 public:
  // Without |ui| (unit tests) nothing asynchronous starts.
  BleHost(BleFlutterApi* events, std::shared_ptr<UiThread> ui = nullptr);
  ~BleHost() override;

  ErrorOr<CapabilitiesMessage> GetCapabilities() override;
  ErrorOr<AdapterStateMessage> GetAdapterState() override;
  void TurnOn(
      std::function<void(std::optional<FlutterError> reply)> result) override;
  ErrorOr<PermissionStatusMessage> GetPermissionStatus() override;
  void RequestPermissions(
      std::function<void(ErrorOr<PermissionStatusMessage> reply)> result)
      override;
  void StartScan(
      const ScanSettingsMessage& settings,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  std::optional<FlutterError> StopScan() override;
  void GetSystemDevices(
      const flutter::EncodableList& service_uuids,
      std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
      override;
  void Connect(
      const std::string& device_id, bool auto_connect,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void Disconnect(
      const std::string& device_id, bool forget,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void DiscoverServices(
      const std::string& device_id,
      std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
      override;
  void ReadCharacteristic(
      const CharacteristicAddressMessage& characteristic,
      std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result)
      override;
  void WriteCharacteristic(
      const CharacteristicAddressMessage& characteristic,
      const std::vector<uint8_t>& value, bool with_response,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void SetNotify(
      const CharacteristicAddressMessage& characteristic, bool enable,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void ReadDescriptor(
      const CharacteristicAddressMessage& characteristic,
      const std::string& descriptor_uuid,
      std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result)
      override;
  void WriteDescriptor(
      const CharacteristicAddressMessage& characteristic,
      const std::string& descriptor_uuid, const std::vector<uint8_t>& value,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void RequestMtu(const std::string& device_id, int64_t mtu,
                  std::function<void(ErrorOr<int64_t> reply)> result) override;
  ErrorOr<int64_t> GetMaximumWriteLength(const std::string& device_id,
                                         bool with_response) override;
  void RequestConnectionPriority(
      const std::string& device_id, const ConnectionPriorityMessage& priority,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void SetPreferredPhy(
      const std::string& device_id, const PhyMessage& tx, const PhyMessage& rx,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void ReadRssi(const std::string& device_id,
                std::function<void(ErrorOr<int64_t> reply)> result) override;
  ErrorOr<BondStateMessage> GetBondState(const std::string& device_id) override;
  void CreateBond(
      const std::string& device_id,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void RemoveBond(
      const std::string& device_id,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void EnableBackgroundMode(
      const BackgroundNotificationMessage& notification,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  std::optional<FlutterError> DisableBackgroundMode() override;
  ErrorOr<bool> IsBackgroundModeEnabled() override;
  ErrorOr<std::optional<SessionMessage>> GetSession(
      const std::string& device_id) override;
  ErrorOr<flutter::EncodableList> GetSessions() override;
  ErrorOr<flutter::EncodableList> TakeBufferedValues() override;

 private:
  using BluetoothLEDevice = winrt::Windows::Devices::Bluetooth::BluetoothLEDevice;
  using GattSession =
      winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession;
  using GattDeviceService =
      winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDeviceService;
  using GattCharacteristic =
      winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic;

  struct Device {
    uint64_t address = 0;
    BluetoothLEDevice device{nullptr};
    GattSession session{nullptr};
    std::vector<GattDeviceService> services;
    // By address key (see Key()).
    std::map<std::string, GattCharacteristic> characteristics;
    std::map<std::string, winrt::event_token> notify_tokens;
    winrt::event_token status_token{};
    winrt::event_token mtu_token{};
    bool connected = false;
    bool disconnecting = false;
  };

  winrt::fire_and_forget InitAdapter();
  winrt::fire_and_forget TurnOnAsync(
      std::function<void(std::optional<FlutterError>)> result);
  winrt::fire_and_forget ConnectAsync(
      std::string device_id,
      std::function<void(std::optional<FlutterError>)> result);
  winrt::fire_and_forget DiscoverAsync(
      std::string device_id,
      std::function<void(ErrorOr<flutter::EncodableList>)> result);
  winrt::fire_and_forget ReadAsync(
      CharacteristicAddressMessage address,
      std::function<void(ErrorOr<std::vector<uint8_t>>)> result);
  winrt::fire_and_forget WriteAsync(
      CharacteristicAddressMessage address, std::vector<uint8_t> value,
      bool with_response,
      std::function<void(std::optional<FlutterError>)> result);
  winrt::fire_and_forget SetNotifyAsync(
      CharacteristicAddressMessage address, bool enable,
      std::function<void(std::optional<FlutterError>)> result);
  winrt::fire_and_forget ReadDescriptorAsync(
      CharacteristicAddressMessage address, std::string uuid,
      std::function<void(ErrorOr<std::vector<uint8_t>>)> result);
  winrt::fire_and_forget WriteDescriptorAsync(
      CharacteristicAddressMessage address, std::string uuid,
      std::vector<uint8_t> value,
      std::function<void(std::optional<FlutterError>)> result);
  winrt::fire_and_forget SystemDevicesAsync(
      std::function<void(ErrorOr<flutter::EncodableList>)> result);
  winrt::fire_and_forget PairAsync(
      std::string device_id, bool pair,
      std::function<void(std::optional<FlutterError>)> result);

  Device* Find(const std::string& device_id);
  Device* Connected(const std::string& device_id);
  void Close(const std::string& device_id);
  void OnConnectionStatusChanged(const std::string& device_id);
  void OnAdvertisement(ScanResultMessage result, uint64_t address);
  void OnValue(CharacteristicValueMessage value);
  void SetAdapterState(AdapterStateMessage state);
  void SendConnectionState(const std::string& device_id,
                           ConnectionStateMessage state,
                           const PlatformErrorMessage* error = nullptr);
  void FlushValues();
  void FlushScanResults();

  BleFlutterApi* events_;
  std::shared_ptr<UiThread> ui_;
  winrt::Windows::Devices::Radios::Radio radio_{nullptr};
  winrt::event_token radio_token_{};
  AdapterStateMessage state_ = AdapterStateMessage::kUnknown;
  bool supported_ = true;
  bool background_mode_ = false;

  winrt::Windows::Devices::Bluetooth::Advertisement::
      BluetoothLEAdvertisementWatcher watcher_{nullptr};
  std::vector<std::string> scan_filter_;
  bool allow_duplicates_ = false;
  std::set<uint64_t> seen_;
  std::vector<ScanResultMessage> pending_scan_;
  bool scan_scheduled_ = false;

  std::map<std::string, std::unique_ptr<Device>> devices_;
  std::vector<CharacteristicValueMessage> pending_values_;
  bool values_scheduled_ = false;
};

// "AA:BB:CC:DD:EE:FF" for a 48-bit address.
std::string FormatAddress(uint64_t address);

// The address in a device ID, or nothing if it isn't a MAC address.
std::optional<uint64_t> ParseAddress(const std::string& device_id);

// Lowercase, without braces.
std::string GuidToString(const winrt::guid& guid);

// The key of a characteristic in Device::characteristics.
std::string Key(const CharacteristicAddressMessage& address);

// The error for calls that this platform can't do.
FlutterError Unsupported(const std::string& message);

// The error for calls that aren't written yet.
FlutterError NotImplemented();

}  // namespace vital_bluetooth

#endif  // FLUTTER_PLUGIN_VITAL_BLUETOOTH_BLE_HOST_H_
