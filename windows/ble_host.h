#ifndef FLUTTER_PLUGIN_VITAL_BLUETOOTH_BLE_HOST_H_
#define FLUTTER_PLUGIN_VITAL_BLUETOOTH_BLE_HOST_H_

#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "messages.g.h"

namespace vital_bluetooth {

// Windows side of BleHostApi, on WinRT Windows.Devices.Bluetooth.
//
// Only the API shape is in place so far. Every call that isn't implemented
// yet answers with an "unsupported" error.
class BleHost : public BleHostApi {
 public:
  explicit BleHost(BleFlutterApi* events);
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
  BleFlutterApi* events_;
};

// The error for calls that this platform can't do.
FlutterError Unsupported(const std::string& message);

// The error for calls that aren't written yet.
FlutterError NotImplemented();

}  // namespace vital_bluetooth

#endif  // FLUTTER_PLUGIN_VITAL_BLUETOOTH_BLE_HOST_H_
