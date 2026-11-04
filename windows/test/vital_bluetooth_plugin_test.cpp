#include <gtest/gtest.h>
#include <windows.h>

#include <optional>
#include <string>

#include "ble_host.h"
#include "messages.g.h"

namespace vital_bluetooth {
namespace test {

TEST(BleHost, ReportsWindowsCapabilities) {
  BleFlutterApi events(nullptr);
  BleHost host(&events);

  ErrorOr<CapabilitiesMessage> caps = host.GetCapabilities();

  ASSERT_FALSE(caps.has_error());
  EXPECT_TRUE(caps.value().ble());
  EXPECT_FALSE(caps.value().classic());
  EXPECT_TRUE(caps.value().bonding());
  EXPECT_FALSE(caps.value().connection_priority());
}

TEST(BleHost, DesktopAppsNeedNoPermission) {
  BleFlutterApi events(nullptr);
  BleHost host(&events);

  ErrorOr<PermissionStatusMessage> status = host.GetPermissionStatus();

  ASSERT_FALSE(status.has_error());
  EXPECT_EQ(status.value(), PermissionStatusMessage::kGranted);
}

TEST(BleHost, WithoutAUiThreadConnectAnswersUnsupported) {
  BleFlutterApi events(nullptr);
  BleHost host(&events);
  std::optional<FlutterError> error;

  host.Connect("AA:BB:CC:DD:EE:FF", false,
               [&error](std::optional<FlutterError> reply) { error = reply; });

  ASSERT_TRUE(error.has_value());
  EXPECT_EQ(error->code(), "unsupported");
}

TEST(Addresses, FormatAndParseRoundTrip) {
  EXPECT_EQ(FormatAddress(0xFCB077691174ULL), "FC:B0:77:69:11:74");
  EXPECT_EQ(ParseAddress("FC:B0:77:69:11:74"), 0xFCB077691174ULL);
  EXPECT_EQ(ParseAddress("fc:b0:77:69:11:74"), 0xFCB077691174ULL);
  EXPECT_FALSE(ParseAddress("not an address").has_value());
}

TEST(Uuids, GuidsBecomeLowercaseWithoutBraces) {
  winrt::guid heart_rate{0x0000180D, 0x0000, 0x1000,
                         {0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB}};
  EXPECT_EQ(GuidToString(heart_rate), "0000180d-0000-1000-8000-00805f9b34fb");
}

TEST(Keys, IncludeInstanceNumbers) {
  CharacteristicAddressMessage a("AA", "s", 1, "c", 2);
  CharacteristicAddressMessage b("AA", "s", 1, "c", 3);
  EXPECT_NE(Key(a), Key(b));
}

}  // namespace test
}  // namespace vital_bluetooth
