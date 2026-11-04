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
  EXPECT_TRUE(caps.value().classic());
  EXPECT_FALSE(caps.value().connection_priority());
}

TEST(BleHost, UnimplementedCallsAnswerUnsupported) {
  BleFlutterApi events(nullptr);
  BleHost host(&events);
  std::optional<FlutterError> error;

  host.Connect("AA:BB", false,
               [&error](std::optional<FlutterError> reply) { error = reply; });

  ASSERT_TRUE(error.has_value());
  EXPECT_EQ(error->code(), "unsupported");
}

}  // namespace test
}  // namespace vital_bluetooth
