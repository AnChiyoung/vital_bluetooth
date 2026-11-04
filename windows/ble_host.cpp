#include "ble_host.h"

namespace vital_bluetooth {

FlutterError Unsupported(const std::string& message) {
  return FlutterError("unsupported", message);
}

FlutterError NotImplemented() {
  return Unsupported("Not implemented on Windows yet.");
}

BleHost::BleHost(BleFlutterApi* events) : events_(events) {}

BleHost::~BleHost() {}

ErrorOr<CapabilitiesMessage> BleHost::GetCapabilities() {
  return CapabilitiesMessage(/*ble=*/true, /*classic=*/true,
                             /*bonding=*/true, /*connection_priority=*/false,
                             /*phy=*/false);
}

ErrorOr<AdapterStateMessage> BleHost::GetAdapterState() {
  return NotImplemented();
}

void BleHost::TurnOn(
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(Unsupported("Apps can't turn Bluetooth on here."));
}

ErrorOr<PermissionStatusMessage> BleHost::GetPermissionStatus() {
  // Desktop apps on Windows don't need a runtime permission.
  return PermissionStatusMessage::kGranted;
}

void BleHost::RequestPermissions(
    std::function<void(ErrorOr<PermissionStatusMessage> reply)> result) {
  result(PermissionStatusMessage::kGranted);
}

void BleHost::StartScan(
    const ScanSettingsMessage& settings,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

std::optional<FlutterError> BleHost::StopScan() { return NotImplemented(); }

void BleHost::GetSystemDevices(
    const flutter::EncodableList& service_uuids,
    std::function<void(ErrorOr<flutter::EncodableList> reply)> result) {
  result(NotImplemented());
}

void BleHost::Connect(
    const std::string& device_id, bool auto_connect,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

void BleHost::Disconnect(
    const std::string& device_id,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

void BleHost::DiscoverServices(
    const std::string& device_id,
    std::function<void(ErrorOr<flutter::EncodableList> reply)> result) {
  result(NotImplemented());
}

void BleHost::ReadCharacteristic(
    const CharacteristicAddressMessage& characteristic,
    std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result) {
  result(NotImplemented());
}

void BleHost::WriteCharacteristic(
    const CharacteristicAddressMessage& characteristic,
    const std::vector<uint8_t>& value, bool with_response,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

void BleHost::SetNotify(
    const CharacteristicAddressMessage& characteristic, bool enable,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

void BleHost::ReadDescriptor(
    const CharacteristicAddressMessage& characteristic,
    const std::string& descriptor_uuid,
    std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result) {
  result(NotImplemented());
}

void BleHost::WriteDescriptor(
    const CharacteristicAddressMessage& characteristic,
    const std::string& descriptor_uuid, const std::vector<uint8_t>& value,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

void BleHost::RequestMtu(const std::string& device_id, int64_t mtu,
                         std::function<void(ErrorOr<int64_t> reply)> result) {
  result(NotImplemented());
}

ErrorOr<int64_t> BleHost::GetMaximumWriteLength(const std::string& device_id,
                                                bool with_response) {
  return NotImplemented();
}

void BleHost::RequestConnectionPriority(
    const std::string& device_id, const ConnectionPriorityMessage& priority,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(Unsupported("Connection priority is Android only."));
}

void BleHost::SetPreferredPhy(
    const std::string& device_id, const PhyMessage& tx, const PhyMessage& rx,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(Unsupported("Choosing the PHY is Android only."));
}

void BleHost::ReadRssi(const std::string& device_id,
                       std::function<void(ErrorOr<int64_t> reply)> result) {
  result(NotImplemented());
}

ErrorOr<BondStateMessage> BleHost::GetBondState(const std::string& device_id) {
  return NotImplemented();
}

void BleHost::CreateBond(
    const std::string& device_id,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

void BleHost::RemoveBond(
    const std::string& device_id,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

}  // namespace vital_bluetooth
