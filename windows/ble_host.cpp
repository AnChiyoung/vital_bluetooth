#include "ble_host.h"

#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <cstdio>
#include <utility>

namespace vital_bluetooth {

namespace {

using namespace winrt::Windows::Devices::Bluetooth;
using namespace winrt::Windows::Devices::Bluetooth::Advertisement;
using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace winrt::Windows::Devices::Enumeration;
using namespace winrt::Windows::Devices::Radios;
using namespace winrt::Windows::Storage::Streams;

using flutter::CustomEncodableValue;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

// 100 ns ticks between 1601-01-01 (Windows) and 1970-01-01 (Unix).
constexpr int64_t kUnixEpochTicks = 116444736000000000;

FlutterError Error(const std::string& code, const std::string& message) {
  return FlutterError(code, message);
}

FlutterError NotConnectedError(const std::string& device_id) {
  return Error("notConnected", device_id + " is not connected.");
}

FlutterError AttributeNotFound(const std::string& uuid) {
  return FlutterError("attributeNotFound", uuid + " was not found.",
                      EncodableValue(uuid));
}

FlutterError FromException(const winrt::hresult_error& e) {
  return FlutterError("unknown", winrt::to_string(e.message()),
                      EncodableValue(std::to_string(e.code().value)));
}

// Turns a GATT result into an error, or nothing on success.
std::optional<FlutterError> GattFailure(
    GattCommunicationStatus status,
    const winrt::Windows::Foundation::IReference<uint8_t>& protocol_error,
    const std::string& device_id) {
  switch (status) {
    case GattCommunicationStatus::Success:
      return std::nullopt;
    case GattCommunicationStatus::Unreachable:
      return NotConnectedError(device_id);
    case GattCommunicationStatus::ProtocolError: {
      int64_t att = protocol_error ? protocol_error.Value() : 0;
      return FlutterError("gattError", "The device answered an error.",
                          EncodableValue(att));
    }
    case GattCommunicationStatus::AccessDenied:
      return Error("unknown", "Windows denied access to the device.");
    default:
      return Error("unknown", "The GATT operation failed.");
  }
}

std::vector<uint8_t> ToBytes(const IBuffer& buffer) {
  std::vector<uint8_t> bytes(buffer ? buffer.Length() : 0);
  if (!bytes.empty()) {
    DataReader::FromBuffer(buffer).ReadBytes(bytes);
  }
  return bytes;
}

IBuffer ToBuffer(const std::vector<uint8_t>& bytes) {
  DataWriter writer;
  writer.WriteBytes(winrt::array_view<const uint8_t>(bytes));
  return writer.DetachBuffer();
}

std::optional<winrt::guid> ParseGuid(const std::string& text) {
  unsigned long data1 = 0;
  unsigned int data2 = 0, data3 = 0;
  unsigned int d[8] = {};
  int read = sscanf_s(text.c_str(),
                      "%8lx-%4x-%4x-%2x%2x-%2x%2x%2x%2x%2x%2x", &data1, &data2,
                      &data3, &d[0], &d[1], &d[2], &d[3], &d[4], &d[5], &d[6],
                      &d[7]);
  if (read != 11) return std::nullopt;
  winrt::guid guid{};
  guid.Data1 = static_cast<uint32_t>(data1);
  guid.Data2 = static_cast<uint16_t>(data2);
  guid.Data3 = static_cast<uint16_t>(data3);
  for (int i = 0; i < 8; i++) guid.Data4[i] = static_cast<uint8_t>(d[i]);
  return guid;
}

std::string OptionalName(const winrt::hstring& name) {
  return winrt::to_string(name);
}

}  // namespace

// --- Free helpers ---

std::string FormatAddress(uint64_t address) {
  char text[18];
  snprintf(text, sizeof(text), "%02X:%02X:%02X:%02X:%02X:%02X",
           static_cast<unsigned>((address >> 40) & 0xFF),
           static_cast<unsigned>((address >> 32) & 0xFF),
           static_cast<unsigned>((address >> 24) & 0xFF),
           static_cast<unsigned>((address >> 16) & 0xFF),
           static_cast<unsigned>((address >> 8) & 0xFF),
           static_cast<unsigned>(address & 0xFF));
  return text;
}

std::optional<uint64_t> ParseAddress(const std::string& device_id) {
  unsigned int b[6] = {};
  if (device_id.size() != 17 ||
      sscanf_s(device_id.c_str(), "%2x:%2x:%2x:%2x:%2x:%2x", &b[0], &b[1],
               &b[2], &b[3], &b[4], &b[5]) != 6) {
    return std::nullopt;
  }
  uint64_t address = 0;
  for (unsigned int byte : b) address = (address << 8) | (byte & 0xFF);
  return address;
}

std::string GuidToString(const winrt::guid& guid) {
  char text[37];
  snprintf(text, sizeof(text),
           "%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
           static_cast<unsigned long>(guid.Data1), unsigned{guid.Data2},
           unsigned{guid.Data3}, unsigned{guid.Data4[0]}, unsigned{guid.Data4[1]},
           unsigned{guid.Data4[2]}, unsigned{guid.Data4[3]}, unsigned{guid.Data4[4]},
           unsigned{guid.Data4[5]}, unsigned{guid.Data4[6]}, unsigned{guid.Data4[7]});
  return text;
}

std::string Key(const CharacteristicAddressMessage& a) {
  return a.service_uuid() + "/" + std::to_string(a.service_instance()) + "/" +
         a.characteristic_uuid() + "/" +
         std::to_string(a.characteristic_instance());
}

FlutterError Unsupported(const std::string& message) {
  return FlutterError("unsupported", message);
}

FlutterError NotImplemented() {
  return Unsupported("Not implemented on Windows yet.");
}

// --- Lifecycle ---

BleHost::BleHost(BleFlutterApi* events, std::shared_ptr<UiThread> ui)
    : events_(events), ui_(std::move(ui)) {
  if (ui_) InitAdapter();
}

BleHost::~BleHost() {
  if (ui_) ui_->Close();
  try {
    if (watcher_) watcher_.Stop();
    if (radio_) radio_.StateChanged(radio_token_);
    for (auto& entry : devices_) {
      Device& d = *entry.second;
      if (d.session) {
        d.session.MaintainConnection(false);
        d.session.Close();
      }
      if (d.device) d.device.Close();
    }
  } catch (...) {
    // Shutting down; nothing useful to do.
  }
}

winrt::fire_and_forget BleHost::InitAdapter() {
  auto ui = ui_;
  try {
    BluetoothAdapter adapter = co_await BluetoothAdapter::GetDefaultAsync();
    co_await ResumeOnUi{ui};
    if (!adapter || !adapter.IsLowEnergySupported()) {
      supported_ = false;
      SetAdapterState(AdapterStateMessage::kUnsupported);
      co_return;
    }
    Radio radio = co_await adapter.GetRadioAsync();
    co_await ResumeOnUi{ui};
    radio_ = radio;
    radio_token_ = radio_.StateChanged([this, ui](const Radio& sender, auto&&) {
      RadioState state = sender.State();
      ui->Post([this, state] {
        SetAdapterState(state == RadioState::On ? AdapterStateMessage::kPoweredOn
                                                : AdapterStateMessage::kPoweredOff);
      });
    });
    SetAdapterState(radio_.State() == RadioState::On
                        ? AdapterStateMessage::kPoweredOn
                        : AdapterStateMessage::kPoweredOff);
  } catch (const winrt::hresult_error&) {
    supported_ = false;
  }
}

void BleHost::SetAdapterState(AdapterStateMessage state) {
  if (state_ == state) return;
  state_ = state;
  events_->OnAdapterStateChanged(state, [] {}, [](const FlutterError&) {});
  if (state != AdapterStateMessage::kPoweredOn && watcher_) {
    watcher_.Stop();
    watcher_ = nullptr;
    PlatformErrorMessage error("poweredOff");
    events_->OnScanStopped(&error, [] {}, [](const FlutterError&) {});
  }
}

// --- Adapter and permissions ---

ErrorOr<CapabilitiesMessage> BleHost::GetCapabilities() {
  return CapabilitiesMessage(/*ble=*/supported_, /*classic=*/false,
                             /*bonding=*/true, /*connection_priority=*/false,
                             /*phy=*/false);
}

ErrorOr<AdapterStateMessage> BleHost::GetAdapterState() { return state_; }

void BleHost::TurnOn(
    std::function<void(std::optional<FlutterError> reply)> result) {
  TurnOnAsync(std::move(result));
}

winrt::fire_and_forget BleHost::TurnOnAsync(
    std::function<void(std::optional<FlutterError>)> result) {
  auto ui = ui_;
  try {
    if (!radio_) {
      result(Unsupported("This PC has no Bluetooth radio."));
      co_return;
    }
    RadioAccessStatus access = co_await Radio::RequestAccessAsync();
    co_await ResumeOnUi{ui};
    if (access != RadioAccessStatus::Allowed) {
      result(Error("permissionDenied", "Windows doesn't let this app turn Bluetooth on."));
      co_return;
    }
    access = co_await radio_.SetStateAsync(RadioState::On);
    co_await ResumeOnUi{ui};
    if (access != RadioAccessStatus::Allowed) {
      result(Error("unknown", "Windows didn't turn Bluetooth on."));
      co_return;
    }
    result(std::nullopt);
  } catch (const winrt::hresult_error& e) {
    result(FromException(e));
  }
}

// Desktop apps need no runtime Bluetooth permission.
ErrorOr<PermissionStatusMessage> BleHost::GetPermissionStatus() {
  return PermissionStatusMessage::kGranted;
}

void BleHost::RequestPermissions(
    std::function<void(ErrorOr<PermissionStatusMessage> reply)> result) {
  result(PermissionStatusMessage::kGranted);
}

// --- Scanning ---

void BleHost::StartScan(
    const ScanSettingsMessage& settings,
    std::function<void(std::optional<FlutterError> reply)> result) {
  if (!ui_ || !supported_) {
    result(Unsupported("This PC has no Bluetooth LE."));
    return;
  }
  if (state_ != AdapterStateMessage::kPoweredOn) {
    result(Error("poweredOff", "Bluetooth is off."));
    return;
  }
  try {
    if (watcher_) watcher_.Stop();
    scan_filter_.clear();
    for (const EncodableValue& uuid : settings.service_uuids()) {
      scan_filter_.push_back(std::get<std::string>(uuid));
    }
    allow_duplicates_ = settings.allow_duplicates();
    seen_.clear();
    watcher_ = BluetoothLEAdvertisementWatcher();
    // Active scanning also gets scan responses, where names often are.
    watcher_.ScanningMode(BluetoothLEScanningMode::Active);
    auto ui = ui_;
    watcher_.Received([this, ui](const BluetoothLEAdvertisementWatcher&,
                                 const BluetoothLEAdvertisementReceivedEventArgs& args) {
      BluetoothLEAdvertisement ad = args.Advertisement();
      EncodableList services;
      for (const winrt::guid& uuid : ad.ServiceUuids()) {
        services.push_back(EncodableValue(GuidToString(uuid)));
      }
      EncodableMap manufacturer;
      for (const BluetoothLEManufacturerData& data : ad.ManufacturerData()) {
        manufacturer[EncodableValue(static_cast<int64_t>(data.CompanyId()))] =
            EncodableValue(ToBytes(data.Data()));
      }
      EncodableMap service_data;
      for (const BluetoothLEAdvertisementDataSection& section : ad.DataSections()) {
        std::vector<uint8_t> bytes = ToBytes(section.Data());
        // 0x16: 16-bit service UUID + data, 0x20: 32-bit, 0x21: 128-bit.
        size_t uuid_size = section.DataType() == 0x16   ? 2
                           : section.DataType() == 0x20 ? 4
                           : section.DataType() == 0x21 ? 16
                                                        : 0;
        if (uuid_size == 0 || bytes.size() < uuid_size) continue;
        std::string uuid;
        if (uuid_size == 16) {
          winrt::guid guid{};
          guid.Data1 = bytes[12] | (bytes[13] << 8) | (bytes[14] << 16) |
                       (static_cast<uint32_t>(bytes[15]) << 24);
          guid.Data2 = static_cast<uint16_t>(bytes[10] | (bytes[11] << 8));
          guid.Data3 = static_cast<uint16_t>(bytes[8] | (bytes[9] << 8));
          for (int i = 0; i < 8; i++) guid.Data4[i] = bytes[7 - i];
          uuid = GuidToString(guid);
        } else {
          uint32_t short_uuid = 0;
          for (size_t i = 0; i < uuid_size; i++) {
            short_uuid |= static_cast<uint32_t>(bytes[i]) << (8 * i);
          }
          char text[37];
          snprintf(text, sizeof(text), "%08x-0000-1000-8000-00805f9b34fb",
                   static_cast<unsigned>(short_uuid));
          uuid = text;
        }
        service_data[EncodableValue(uuid)] = EncodableValue(
            std::vector<uint8_t>(bytes.begin() + uuid_size, bytes.end()));
      }
      std::string name = OptionalName(ad.LocalName());
      std::optional<int64_t> tx_power;
      if (auto power = args.TransmitPowerLevelInDBm()) tx_power = power.Value();
      uint64_t address = args.BluetoothAddress();
      ScanResultMessage scan(
          FormatAddress(address), name.empty() ? nullptr : &name,
          args.RawSignalStrengthInDBm(), args.IsConnectable(),
          tx_power ? &*tx_power : nullptr, services, manufacturer, service_data);
      ui->Post([this, scan = std::move(scan), address]() mutable {
        OnAdvertisement(std::move(scan), address);
      });
    });
    watcher_.Stopped([this, ui](const BluetoothLEAdvertisementWatcher& sender,
                                const BluetoothLEAdvertisementWatcherStoppedEventArgs& args) {
      BluetoothError error = args.Error();
      ui->Post([this, sender, error] {
        if (watcher_ != sender) return;  // Replaced or stopped by us.
        watcher_ = nullptr;
        if (error == BluetoothError::Success) {
          events_->OnScanStopped(nullptr, [] {}, [](const FlutterError&) {});
          return;
        }
        PlatformErrorMessage message(
            error == BluetoothError::RadioNotAvailable ? "poweredOff" : "unknown");
        events_->OnScanStopped(&message, [] {}, [](const FlutterError&) {});
      });
    });
    watcher_.Start();
    result(std::nullopt);
  } catch (const winrt::hresult_error& e) {
    watcher_ = nullptr;
    result(FromException(e));
  }
}

void BleHost::OnAdvertisement(ScanResultMessage result, uint64_t address) {
  if (!watcher_) return;
  if (!scan_filter_.empty()) {
    bool match = false;
    for (const EncodableValue& uuid : result.service_uuids()) {
      const auto& text = std::get<std::string>(uuid);
      if (std::find(scan_filter_.begin(), scan_filter_.end(), text) !=
          scan_filter_.end()) {
        match = true;
        break;
      }
    }
    if (!match) return;
  }
  if (!allow_duplicates_ && !seen_.insert(address).second) return;
  pending_scan_.push_back(std::move(result));
  if (scan_scheduled_) return;
  scan_scheduled_ = true;
  ui_->Post([this] { FlushScanResults(); });
}

void BleHost::FlushScanResults() {
  scan_scheduled_ = false;
  if (pending_scan_.empty()) return;
  EncodableList batch;
  for (auto& result : pending_scan_) batch.push_back(CustomEncodableValue(result));
  pending_scan_.clear();
  events_->OnScanResults(batch, [] {}, [](const FlutterError&) {});
}

std::optional<FlutterError> BleHost::StopScan() {
  if (!watcher_) return std::nullopt;
  try {
    auto watcher = watcher_;
    watcher_ = nullptr;  // So the Stopped event isn't reported as our own.
    watcher.Stop();
  } catch (const winrt::hresult_error& e) {
    return FromException(e);
  }
  return std::nullopt;
}

void BleHost::GetSystemDevices(
    const flutter::EncodableList& service_uuids,
    std::function<void(ErrorOr<flutter::EncodableList> reply)> result) {
  // Windows can't filter connected devices by service without connecting.
  if (!ui_) {
    result(EncodableList());
    return;
  }
  SystemDevicesAsync(std::move(result));
}

winrt::fire_and_forget BleHost::SystemDevicesAsync(
    std::function<void(ErrorOr<flutter::EncodableList>)> result) {
  auto ui = ui_;
  try {
    auto selector = BluetoothLEDevice::GetDeviceSelectorFromConnectionStatus(
        BluetoothConnectionStatus::Connected);
    auto infos = co_await DeviceInformation::FindAllAsync(selector);
    EncodableList found;
    for (const DeviceInformation& info : infos) {
      BluetoothLEDevice device = co_await BluetoothLEDevice::FromIdAsync(info.Id());
      if (!device) continue;
      std::string name = winrt::to_string(device.Name());
      found.push_back(CustomEncodableValue(SystemDeviceMessage(
          FormatAddress(device.BluetoothAddress()), name.empty() ? nullptr : &name)));
      device.Close();
    }
    co_await ResumeOnUi{ui};
    result(found);
  } catch (const winrt::hresult_error& e) {
    result(FromException(e));
  }
}

// --- Connection ---

BleHost::Device* BleHost::Find(const std::string& device_id) {
  auto it = devices_.find(device_id);
  return it == devices_.end() ? nullptr : it->second.get();
}

BleHost::Device* BleHost::Connected(const std::string& device_id) {
  Device* d = Find(device_id);
  return d != nullptr && d->connected ? d : nullptr;
}

void BleHost::SendConnectionState(const std::string& device_id,
                                  ConnectionStateMessage state,
                                  const PlatformErrorMessage* error) {
  // Values received before a drop must reach Dart before the drop.
  FlushValues();
  events_->OnConnectionStateChanged(device_id, state, error, [] {},
                                    [](const FlutterError&) {});
}

void BleHost::Connect(
    const std::string& device_id, bool auto_connect,
    std::function<void(std::optional<FlutterError> reply)> result) {
  if (!ui_ || !supported_) {
    result(Unsupported("This PC has no Bluetooth LE."));
    return;
  }
  if (state_ != AdapterStateMessage::kPoweredOn) {
    result(Error("poweredOff", "Bluetooth is off."));
    return;
  }
  ConnectAsync(device_id, std::move(result));
}

winrt::fire_and_forget BleHost::ConnectAsync(
    std::string device_id,
    std::function<void(std::optional<FlutterError>)> result) {
  auto ui = ui_;
  try {
    std::optional<uint64_t> address = ParseAddress(device_id);
    if (!address) {
      result(Error("deviceNotFound", device_id + " is not a Bluetooth address."));
      co_return;
    }
    if (Connected(device_id) != nullptr) {
      result(std::nullopt);
      co_return;
    }
    if (Find(device_id) == nullptr) {
      auto d = std::make_unique<Device>();
      d->address = *address;
      devices_[device_id] = std::move(d);
    }
    SendConnectionState(device_id, ConnectionStateMessage::kConnecting);

    if (!Find(device_id)->device) {
      BluetoothLEDevice device =
          co_await BluetoothLEDevice::FromBluetoothAddressAsync(*address);
      co_await ResumeOnUi{ui};
      Device* d = Find(device_id);
      if (d == nullptr) {
        result(NotConnectedError(device_id));  // Disconnected meanwhile.
        co_return;
      }
      if (!device) {
        devices_.erase(device_id);
        SendConnectionState(device_id, ConnectionStateMessage::kDisconnected);
        result(Error("deviceNotFound", "Windows can't find " + device_id + "."));
        co_return;
      }
      d->device = device;
      d->status_token = device.ConnectionStatusChanged(
          [this, ui, device_id](const BluetoothLEDevice&, auto&&) {
            ui->Post([this, device_id] { OnConnectionStatusChanged(device_id); });
          });
    }

    if (!Find(device_id)->session) {
      GattSession session = co_await GattSession::FromDeviceIdAsync(
          Find(device_id)->device.BluetoothDeviceId());
      co_await ResumeOnUi{ui};
      Device* d = Find(device_id);
      if (d == nullptr) {
        session.Close();
        result(NotConnectedError(device_id));
        co_return;
      }
      d->session = session;
      // Keep the link up, and let Windows restore it when it drops.
      session.MaintainConnection(true);
      d->mtu_token = session.MaxPduSizeChanged(
          [this, ui, device_id](const GattSession& sender, auto&&) {
            int64_t mtu = sender.MaxPduSize();
            ui->Post([this, device_id, mtu] {
              events_->OnMtuChanged(device_id, mtu, [] {},
                                    [](const FlutterError&) {});
            });
          });
    }

    // Reading the services opens the link.
    GattDeviceServicesResult services = co_await Find(device_id)->device
        .GetGattServicesAsync(BluetoothCacheMode::Uncached);
    co_await ResumeOnUi{ui};
    Device* d = Find(device_id);
    if (d == nullptr) {
      result(NotConnectedError(device_id));
      co_return;
    }
    if (services.Status() != GattCommunicationStatus::Success) {
      // Keep the session: Windows keeps trying, which serves as the next
      // attempt if Dart retries.
      SendConnectionState(device_id, ConnectionStateMessage::kDisconnected);
      result(FlutterError(
          "connectionFailed", "Connecting to " + device_id + " failed.",
          EncodableValue(std::to_string(static_cast<int>(services.Status())))));
      co_return;
    }
    d->services.clear();
    for (const GattDeviceService& s : services.Services()) d->services.push_back(s);
    d->connected = true;
    d->disconnecting = false;
    SendConnectionState(device_id, ConnectionStateMessage::kConnected);
    result(std::nullopt);
  } catch (const winrt::hresult_error& e) {
    result(FromException(e));
  }
}

void BleHost::OnConnectionStatusChanged(const std::string& device_id) {
  Device* d = Find(device_id);
  if (d == nullptr || !d->device) return;
  bool up = d->device.ConnectionStatus() == BluetoothConnectionStatus::Connected;
  if (!up && d->connected && !d->disconnecting) {
    d->connected = false;
    d->characteristics.clear();
    PlatformErrorMessage error("notConnected");
    SendConnectionState(device_id, ConnectionStateMessage::kDisconnected, &error);
  }
}

void BleHost::Disconnect(
    const std::string& device_id, bool forget,
    std::function<void(std::optional<FlutterError> reply)> result) {
  Device* d = Find(device_id);
  if (d == nullptr) {
    result(std::nullopt);
    return;
  }
  if (!forget && !d->connected) {
    // Only a failed attempt is being cleaned up. Windows keeps trying while
    // the session stays open, which is the best next attempt.
    result(std::nullopt);
    return;
  }
  bool was_connected = d->connected;
  d->disconnecting = true;
  if (was_connected) {
    SendConnectionState(device_id, ConnectionStateMessage::kDisconnecting);
  }
  Close(device_id);
  SendConnectionState(device_id, ConnectionStateMessage::kDisconnected);
  result(std::nullopt);
}

void BleHost::Close(const std::string& device_id) {
  Device* d = Find(device_id);
  if (d == nullptr) return;
  try {
    for (auto& entry : d->notify_tokens) {
      auto it = d->characteristics.find(entry.first);
      if (it != d->characteristics.end()) it->second.ValueChanged(entry.second);
    }
    if (d->session) {
      d->session.MaxPduSizeChanged(d->mtu_token);
      d->session.MaintainConnection(false);
      d->session.Close();
    }
    for (auto& service : d->services) service.Close();
    if (d->device) {
      d->device.ConnectionStatusChanged(d->status_token);
      d->device.Close();
    }
  } catch (const winrt::hresult_error&) {
    // The link is treated as closed either way.
  }
  devices_.erase(device_id);
}

void BleHost::DiscoverServices(
    const std::string& device_id,
    std::function<void(ErrorOr<flutter::EncodableList> reply)> result) {
  if (Connected(device_id) == nullptr) {
    result(NotConnectedError(device_id));
    return;
  }
  DiscoverAsync(device_id, std::move(result));
}

winrt::fire_and_forget BleHost::DiscoverAsync(
    std::string device_id,
    std::function<void(ErrorOr<flutter::EncodableList>)> result) {
  auto ui = ui_;
  try {
    GattDeviceServicesResult services = co_await Connected(device_id)->device
        .GetGattServicesAsync(BluetoothCacheMode::Cached);
    co_await ResumeOnUi{ui};
    if (Connected(device_id) == nullptr) {
      result(NotConnectedError(device_id));
      co_return;
    }
    if (auto failure = GattFailure(services.Status(), services.ProtocolError(), device_id)) {
      result(*failure);
      co_return;
    }
    std::map<std::string, GattCharacteristic> characteristics;
    std::vector<GattDeviceService> service_list;
    EncodableList messages;
    for (const GattDeviceService& service : services.Services()) {
      service_list.push_back(service);
      std::string service_uuid = GuidToString(service.Uuid());
      int64_t service_instance = service.AttributeHandle();
      GattCharacteristicsResult chars =
          co_await service.GetCharacteristicsAsync(BluetoothCacheMode::Uncached);
      co_await ResumeOnUi{ui};
      EncodableList char_messages;
      if (chars.Status() == GattCommunicationStatus::Success) {
        for (const GattCharacteristic& c : chars.Characteristics()) {
          auto p = c.CharacteristicProperties();
          auto has = [p](GattCharacteristicProperties flag) {
            return (p & flag) == flag;
          };
          EncodableList descriptors;
          GattDescriptorsResult descs =
              co_await c.GetDescriptorsAsync(BluetoothCacheMode::Uncached);
          co_await ResumeOnUi{ui};
          if (descs.Status() == GattCommunicationStatus::Success) {
            for (const GattDescriptor& desc : descs.Descriptors()) {
              descriptors.push_back(
                  CustomEncodableValue(DescriptorMessage(GuidToString(desc.Uuid()))));
            }
          }
          std::string char_uuid = GuidToString(c.Uuid());
          int64_t char_instance = c.AttributeHandle();
          CharacteristicAddressMessage address(device_id, service_uuid, service_instance,
                                               char_uuid, char_instance);
          characteristics.insert_or_assign(Key(address), c);
          char_messages.push_back(CustomEncodableValue(CharacteristicMessage(
              char_uuid, char_instance,
              CharacteristicPropertiesMessage(
                  has(GattCharacteristicProperties::Broadcast),
                  has(GattCharacteristicProperties::Read),
                  has(GattCharacteristicProperties::WriteWithoutResponse),
                  has(GattCharacteristicProperties::Write),
                  has(GattCharacteristicProperties::Notify),
                  has(GattCharacteristicProperties::Indicate),
                  has(GattCharacteristicProperties::AuthenticatedSignedWrites),
                  has(GattCharacteristicProperties::ExtendedProperties)),
              descriptors)));
        }
      }
      messages.push_back(CustomEncodableValue(ServiceMessage(
          service_uuid, service_instance, /*is_primary=*/true, char_messages,
          EncodableList())));
    }
    Device* d = Connected(device_id);
    if (d == nullptr) {
      result(NotConnectedError(device_id));
      co_return;
    }
    // Notifications stay registered across a rediscovery.
    for (auto& entry : characteristics) {
      auto old = d->characteristics.find(entry.first);
      auto token = d->notify_tokens.find(entry.first);
      if (old != d->characteristics.end() && token != d->notify_tokens.end()) {
        entry.second = old->second;
      }
    }
    d->characteristics = std::move(characteristics);
    d->services = std::move(service_list);
    result(messages);
  } catch (const winrt::hresult_error& e) {
    result(FromException(e));
  }
}

// --- GATT ---

void BleHost::ReadCharacteristic(
    const CharacteristicAddressMessage& characteristic,
    std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result) {
  ReadAsync(characteristic, std::move(result));
}

winrt::fire_and_forget BleHost::ReadAsync(
    CharacteristicAddressMessage address,
    std::function<void(ErrorOr<std::vector<uint8_t>>)> result) {
  auto ui = ui_;
  try {
    Device* d = Connected(address.device_id());
    if (d == nullptr) {
      result(NotConnectedError(address.device_id()));
      co_return;
    }
    auto it = d->characteristics.find(Key(address));
    if (it == d->characteristics.end()) {
      result(AttributeNotFound(address.characteristic_uuid()));
      co_return;
    }
    GattReadResult read = co_await it->second.ReadValueAsync(BluetoothCacheMode::Uncached);
    co_await ResumeOnUi{ui};
    if (auto failure = GattFailure(read.Status(), read.ProtocolError(), address.device_id())) {
      result(*failure);
      co_return;
    }
    result(ToBytes(read.Value()));
  } catch (const winrt::hresult_error& e) {
    result(FromException(e));
  }
}

void BleHost::WriteCharacteristic(
    const CharacteristicAddressMessage& characteristic,
    const std::vector<uint8_t>& value, bool with_response,
    std::function<void(std::optional<FlutterError> reply)> result) {
  WriteAsync(characteristic, value, with_response, std::move(result));
}

winrt::fire_and_forget BleHost::WriteAsync(
    CharacteristicAddressMessage address, std::vector<uint8_t> value,
    bool with_response, std::function<void(std::optional<FlutterError>)> result) {
  auto ui = ui_;
  try {
    Device* d = Connected(address.device_id());
    if (d == nullptr) {
      result(NotConnectedError(address.device_id()));
      co_return;
    }
    auto it = d->characteristics.find(Key(address));
    if (it == d->characteristics.end()) {
      result(AttributeNotFound(address.characteristic_uuid()));
      co_return;
    }
    GattWriteResult write = co_await it->second.WriteValueWithResultAsync(
        ToBuffer(value), with_response ? GattWriteOption::WriteWithResponse
                                       : GattWriteOption::WriteWithoutResponse);
    co_await ResumeOnUi{ui};
    result(GattFailure(write.Status(), write.ProtocolError(), address.device_id()));
  } catch (const winrt::hresult_error& e) {
    result(FromException(e));
  }
}

void BleHost::SetNotify(
    const CharacteristicAddressMessage& characteristic, bool enable,
    std::function<void(std::optional<FlutterError> reply)> result) {
  SetNotifyAsync(characteristic, enable, std::move(result));
}

winrt::fire_and_forget BleHost::SetNotifyAsync(
    CharacteristicAddressMessage address, bool enable,
    std::function<void(std::optional<FlutterError>)> result) {
  auto ui = ui_;
  try {
    Device* d = Connected(address.device_id());
    if (d == nullptr) {
      result(NotConnectedError(address.device_id()));
      co_return;
    }
    std::string key = Key(address);
    auto it = d->characteristics.find(key);
    if (it == d->characteristics.end()) {
      result(AttributeNotFound(address.characteristic_uuid()));
      co_return;
    }
    GattCharacteristic characteristic = it->second;
    auto properties = characteristic.CharacteristicProperties();
    auto value = GattClientCharacteristicConfigurationDescriptorValue::None;
    if (enable) {
      if ((properties & GattCharacteristicProperties::Notify) ==
          GattCharacteristicProperties::Notify) {
        value = GattClientCharacteristicConfigurationDescriptorValue::Notify;
      } else if ((properties & GattCharacteristicProperties::Indicate) ==
                 GattCharacteristicProperties::Indicate) {
        value = GattClientCharacteristicConfigurationDescriptorValue::Indicate;
      } else {
        result(Unsupported(address.characteristic_uuid() +
                           " supports neither notify nor indicate."));
        co_return;
      }
      if (d->notify_tokens.find(key) == d->notify_tokens.end()) {
        d->notify_tokens[key] = characteristic.ValueChanged(
            [this, ui, address](const GattCharacteristic&,
                                const GattValueChangedEventArgs& args) {
              int64_t micros =
                  (args.Timestamp().time_since_epoch().count() - kUnixEpochTicks) / 10;
              CharacteristicValueMessage message(
                  address, ToBytes(args.CharacteristicValue()), micros);
              ui->Post([this, message = std::move(message)]() mutable {
                OnValue(std::move(message));
              });
            });
      }
    }
    GattWriteResult write =
        co_await characteristic
            .WriteClientCharacteristicConfigurationDescriptorWithResultAsync(value);
    co_await ResumeOnUi{ui};
    std::optional<FlutterError> failure =
        GattFailure(write.Status(), write.ProtocolError(), address.device_id());
    Device* now = Find(address.device_id());
    if (now != nullptr && (!enable || failure)) {
      auto token = now->notify_tokens.find(key);
      if (token != now->notify_tokens.end()) {
        characteristic.ValueChanged(token->second);
        now->notify_tokens.erase(token);
      }
    }
    result(failure);
  } catch (const winrt::hresult_error& e) {
    result(FromException(e));
  }
}

void BleHost::OnValue(CharacteristicValueMessage value) {
  pending_values_.push_back(std::move(value));
  if (values_scheduled_) return;
  values_scheduled_ = true;
  ui_->Post([this] { FlushValues(); });
}

void BleHost::FlushValues() {
  values_scheduled_ = false;
  if (pending_values_.empty()) return;
  EncodableList batch;
  for (auto& value : pending_values_) batch.push_back(CustomEncodableValue(value));
  pending_values_.clear();
  events_->OnCharacteristicValues(batch, [] {}, [](const FlutterError&) {});
}

void BleHost::ReadDescriptor(
    const CharacteristicAddressMessage& characteristic,
    const std::string& descriptor_uuid,
    std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result) {
  ReadDescriptorAsync(characteristic, descriptor_uuid, std::move(result));
}

winrt::fire_and_forget BleHost::ReadDescriptorAsync(
    CharacteristicAddressMessage address, std::string uuid,
    std::function<void(ErrorOr<std::vector<uint8_t>>)> result) {
  auto ui = ui_;
  try {
    Device* d = Connected(address.device_id());
    std::optional<winrt::guid> guid = ParseGuid(uuid);
    if (d == nullptr || !guid) {
      result(d == nullptr ? NotConnectedError(address.device_id()) : AttributeNotFound(uuid));
      co_return;
    }
    auto it = d->characteristics.find(Key(address));
    if (it == d->characteristics.end()) {
      result(AttributeNotFound(address.characteristic_uuid()));
      co_return;
    }
    GattDescriptorsResult descs =
        co_await it->second.GetDescriptorsForUuidAsync(*guid, BluetoothCacheMode::Cached);
    co_await ResumeOnUi{ui};
    if (descs.Status() != GattCommunicationStatus::Success || descs.Descriptors().Size() == 0) {
      result(AttributeNotFound(uuid));
      co_return;
    }
    GattReadResult read =
        co_await descs.Descriptors().GetAt(0).ReadValueAsync(BluetoothCacheMode::Uncached);
    co_await ResumeOnUi{ui};
    if (auto failure = GattFailure(read.Status(), read.ProtocolError(), address.device_id())) {
      result(*failure);
      co_return;
    }
    result(ToBytes(read.Value()));
  } catch (const winrt::hresult_error& e) {
    result(FromException(e));
  }
}

void BleHost::WriteDescriptor(
    const CharacteristicAddressMessage& characteristic,
    const std::string& descriptor_uuid, const std::vector<uint8_t>& value,
    std::function<void(std::optional<FlutterError> reply)> result) {
  WriteDescriptorAsync(characteristic, descriptor_uuid, value, std::move(result));
}

winrt::fire_and_forget BleHost::WriteDescriptorAsync(
    CharacteristicAddressMessage address, std::string uuid,
    std::vector<uint8_t> value,
    std::function<void(std::optional<FlutterError>)> result) {
  auto ui = ui_;
  try {
    Device* d = Connected(address.device_id());
    std::optional<winrt::guid> guid = ParseGuid(uuid);
    if (d == nullptr || !guid) {
      result(d == nullptr ? NotConnectedError(address.device_id()) : AttributeNotFound(uuid));
      co_return;
    }
    auto it = d->characteristics.find(Key(address));
    if (it == d->characteristics.end()) {
      result(AttributeNotFound(address.characteristic_uuid()));
      co_return;
    }
    GattDescriptorsResult descs =
        co_await it->second.GetDescriptorsForUuidAsync(*guid, BluetoothCacheMode::Cached);
    co_await ResumeOnUi{ui};
    if (descs.Status() != GattCommunicationStatus::Success || descs.Descriptors().Size() == 0) {
      result(AttributeNotFound(uuid));
      co_return;
    }
    GattWriteResult write =
        co_await descs.Descriptors().GetAt(0).WriteValueWithResultAsync(ToBuffer(value));
    co_await ResumeOnUi{ui};
    result(GattFailure(write.Status(), write.ProtocolError(), address.device_id()));
  } catch (const winrt::hresult_error& e) {
    result(FromException(e));
  }
}

void BleHost::RequestMtu(const std::string& device_id, int64_t mtu,
                         std::function<void(ErrorOr<int64_t> reply)> result) {
  // Windows negotiates the MTU itself; report the current one.
  Device* d = Connected(device_id);
  if (d == nullptr || !d->session) {
    result(NotConnectedError(device_id));
    return;
  }
  result(static_cast<int64_t>(d->session.MaxPduSize()));
}

ErrorOr<int64_t> BleHost::GetMaximumWriteLength(const std::string& device_id,
                                                bool with_response) {
  Device* d = Connected(device_id);
  if (d == nullptr || !d->session) return NotConnectedError(device_id);
  int64_t payload = static_cast<int64_t>(d->session.MaxPduSize()) - 3;
  // A long write can't exceed 512 bytes per attribute.
  return with_response ? std::min<int64_t>(payload, 512) : payload;
}

void BleHost::RequestConnectionPriority(
    const std::string& device_id, const ConnectionPriorityMessage& priority,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(Unsupported("Windows chooses the connection parameters itself."));
}

void BleHost::SetPreferredPhy(
    const std::string& device_id, const PhyMessage& tx, const PhyMessage& rx,
    std::function<void(std::optional<FlutterError> reply)> result) {
  result(Unsupported("Windows chooses the PHY itself."));
}

void BleHost::ReadRssi(const std::string& device_id,
                       std::function<void(ErrorOr<int64_t> reply)> result) {
  result(Unsupported("Windows doesn't report the RSSI of a connected device."));
}

// --- Bonding ---

ErrorOr<BondStateMessage> BleHost::GetBondState(const std::string& device_id) {
  Device* d = Find(device_id);
  if (d == nullptr || !d->device) {
    // The device object only exists after a connect; unknown means unpaired
    // as far as this app can tell without waiting.
    return BondStateMessage::kNone;
  }
  try {
    return d->device.DeviceInformation().Pairing().IsPaired()
               ? BondStateMessage::kBonded
               : BondStateMessage::kNone;
  } catch (const winrt::hresult_error& e) {
    return FromException(e);
  }
}

void BleHost::CreateBond(
    const std::string& device_id,
    std::function<void(std::optional<FlutterError> reply)> result) {
  if (!ui_) {
    result(Unsupported("This PC has no Bluetooth LE."));
    return;
  }
  PairAsync(device_id, true, std::move(result));
}

void BleHost::RemoveBond(
    const std::string& device_id,
    std::function<void(std::optional<FlutterError> reply)> result) {
  if (!ui_) {
    result(Unsupported("This PC has no Bluetooth LE."));
    return;
  }
  PairAsync(device_id, false, std::move(result));
}

winrt::fire_and_forget BleHost::PairAsync(
    std::string device_id, bool pair,
    std::function<void(std::optional<FlutterError>)> result) {
  auto ui = ui_;
  try {
    std::optional<uint64_t> address = ParseAddress(device_id);
    if (!address) {
      result(Error("deviceNotFound", device_id + " is not a Bluetooth address."));
      co_return;
    }
    BluetoothLEDevice device{nullptr};
    if (Device* d = Find(device_id); d != nullptr && d->device) {
      device = d->device;
    } else {
      device = co_await BluetoothLEDevice::FromBluetoothAddressAsync(*address);
      co_await ResumeOnUi{ui};
    }
    if (!device) {
      result(Error("deviceNotFound", "Windows can't find " + device_id + "."));
      co_return;
    }
    DeviceInformationPairing pairing = device.DeviceInformation().Pairing();
    if (pair) {
      if (!pairing.IsPaired()) {
        events_->OnBondStateChanged(device_id, BondStateMessage::kBonding, [] {},
                                    [](const FlutterError&) {});
        DevicePairingResult paired = co_await pairing.PairAsync();
        co_await ResumeOnUi{ui};
        auto status = paired.Status();
        if (status != DevicePairingResultStatus::Paired &&
            status != DevicePairingResultStatus::AlreadyPaired) {
          events_->OnBondStateChanged(device_id, BondStateMessage::kNone, [] {},
                                      [](const FlutterError&) {});
          result(FlutterError("bondingFailed", "Pairing with " + device_id + " failed.",
                              EncodableValue(std::to_string(static_cast<int>(status)))));
          co_return;
        }
      }
      events_->OnBondStateChanged(device_id, BondStateMessage::kBonded, [] {},
                                  [](const FlutterError&) {});
    } else {
      if (pairing.IsPaired()) {
        DeviceUnpairingResult unpaired = co_await pairing.UnpairAsync();
        co_await ResumeOnUi{ui};
        auto status = unpaired.Status();
        if (status != DeviceUnpairingResultStatus::Unpaired &&
            status != DeviceUnpairingResultStatus::AlreadyUnpaired) {
          result(Error("unknown", "Windows didn't remove the bond."));
          co_return;
        }
      }
      events_->OnBondStateChanged(device_id, BondStateMessage::kNone, [] {},
                                  [](const FlutterError&) {});
    }
    result(std::nullopt);
  } catch (const winrt::hresult_error& e) {
    result(FromException(e));
  }
}

// --- Background mode ---
//
// Desktop apps aren't suspended or killed in the background, and links live
// as long as the app, so there is nothing to keep alive beyond the flag.

void BleHost::EnableBackgroundMode(
    const BackgroundNotificationMessage& notification,
    std::function<void(std::optional<FlutterError> reply)> result) {
  background_mode_ = true;
  result(std::nullopt);
}

std::optional<FlutterError> BleHost::DisableBackgroundMode() {
  background_mode_ = false;
  return std::nullopt;
}

ErrorOr<bool> BleHost::IsBackgroundModeEnabled() { return background_mode_; }

ErrorOr<std::optional<SessionMessage>> BleHost::GetSession(
    const std::string& device_id) {
  return std::optional<SessionMessage>();
}

ErrorOr<flutter::EncodableList> BleHost::GetSessions() {
  return flutter::EncodableList();
}

ErrorOr<flutter::EncodableList> BleHost::TakeBufferedValues() {
  return flutter::EncodableList();
}

}  // namespace vital_bluetooth
