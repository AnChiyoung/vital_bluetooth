#ifndef FLUTTER_PLUGIN_VITAL_BLUETOOTH_CLASSIC_HOST_H_
#define FLUTTER_PLUGIN_VITAL_BLUETOOTH_CLASSIC_HOST_H_

#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "messages.g.h"

namespace vital_bluetooth {

// Windows side of ClassicHostApi (RFCOMM / SPP).
//
// Only the API shape is in place so far.
class ClassicHost : public ClassicHostApi {
 public:
  explicit ClassicHost(ClassicFlutterApi* events);
  ~ClassicHost() override;

  void GetBondedDevices(
      std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
      override;
  void StartDiscovery(
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void StopDiscovery(
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void Connect(
      const std::string& device_id, const std::string& service_uuid,
      bool secure,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void Disconnect(
      const std::string& device_id,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void Write(
      const std::string& device_id, const std::vector<uint8_t>& data,
      std::function<void(std::optional<FlutterError> reply)> result) override;

 private:
  ClassicFlutterApi* events_;
};

}  // namespace vital_bluetooth

#endif  // FLUTTER_PLUGIN_VITAL_BLUETOOTH_CLASSIC_HOST_H_
