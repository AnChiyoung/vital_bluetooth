#include "classic_host.h"

#include "ble_host.h"

namespace vital_bluetooth {

ClassicHost::ClassicHost(ClassicFlutterApi* events) : events_(events) {}

ClassicHost::~ClassicHost() {}

void ClassicHost::GetBondedDevices(
    std::function<void(ErrorOr<flutter::EncodableList> reply)> result) {
  result(NotImplemented());
}

void ClassicHost::StartDiscovery(
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

void ClassicHost::StopDiscovery(
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

void ClassicHost::Connect(
    const std::string& device_id, const std::string& service_uuid, bool secure,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

void ClassicHost::Disconnect(
    const std::string& device_id,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

void ClassicHost::Write(
    const std::string& device_id, const std::vector<uint8_t>& data,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(NotImplemented());
}

}  // namespace vital_bluetooth
