# vital_bluetooth

Bluetooth LE for Flutter, built for wearables and healthcare devices that
have to **stay connected** and keep streaming data, even while the app is in
the background or its screen has been closed.

- **Background mode.** Links survive the app going to the background, the
  screen turning off, and the app's UI being closed. A dropped link is
  restored in native code and notifications are turned back on. Values that
  arrive while no Dart code runs are kept for you.
- **Automatic reconnect.** Dropped links come back with backoff, and every
  notification you turned on is turned on again.
- **Queued GATT operations.** Reads, writes and notification changes run one
  at a time per device, so concurrent calls never collide.
- **Android quirks handled.** GATT status 133 is retried, every connection
  is closed properly, and location being off on Android 7–11 is reported
  instead of returning an empty scan.
- **Typed errors.** A sealed exception hierarchy you can `switch` over, with
  the raw native code kept for logging.
- **State-management friendly.** Adapter state, scanning, connection state,
  services, MTU and names are `ValueListenable`s; scans and values are
  `Stream`s.

## Platform support

| | Android | iOS | macOS | Windows |
|---|:---:|:---:|:---:|:---:|
| Scan, connect, GATT, notifications | ✅ | ✅ | ✅ | ✅ |
| Background mode | ✅ | ✅ | ✅ | ✅ |
| Bonding from the app | ✅ | – | – | ✅ |
| Read RSSI of a connected device | ✅ | ✅ | ✅ | – |
| MTU request | ✅ | auto | auto | auto |
| Connection priority, PHY | ✅ | – | – | – |
| Turn Bluetooth on | ✅ | – | – | ✅ |

– means the platform doesn't let apps do it. "auto" means the system
negotiates the MTU itself; `requestMtu` returns the current value.

Bluetooth Classic (SPP) is planned.

Minimum versions: Flutter 3.29 (Dart 3.7), Android 7.0 (API 24), iOS 15,
macOS 12, Windows 10 (version 2004).

## Installation

```yaml
dependencies:
  vital_bluetooth: ^0.1.0
```

### Android

The app's `minSdk` must be 24 or higher. Recent Flutter versions already
default to 24; if yours uses `flutter.minSdkVersion` and the build reports
a lower value, set it in `android/app/build.gradle(.kts)`:

```kotlin
defaultConfig {
    minSdk = 24
}
```

Nothing else to add. The plugin's manifest declares:

- Android 12+: `BLUETOOTH_SCAN` (with `neverForLocation`) and
  `BLUETOOTH_CONNECT`
- Android 11 and lower: `BLUETOOTH`, `BLUETOOTH_ADMIN` and
  `ACCESS_FINE_LOCATION`
- Background mode: `FOREGROUND_SERVICE`,
  `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `POST_NOTIFICATIONS` and the
  foreground service

If your app needs to derive location from scans (beacons), remove the
`neverForLocation` flag in your own manifest:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    tools:remove="android:usesPermissionFlags" />
```

If your app never uses background mode, you can remove its permissions and
service so Google Play doesn't ask you to declare a foreground service:

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"
    tools:node="remove" />
<service android:name="dev.goodluckcy.vital_bluetooth.VitalBluetoothService"
    tools:node="remove" />
```

The background-mode notification uses a drawable named
`vital_bluetooth_notification` if your app has one, and the app icon
otherwise.

### iOS

Add to `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Connects to your heart rate monitor.</string>
<!-- Only for background mode: -->
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
</array>
```

### macOS

Add `NSBluetoothAlwaysUsageDescription` to `macos/Runner/Info.plist`, and
to both `DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
```

### Windows

Nothing to add.

## Quick start

```dart
import 'package:vital_bluetooth/vital_bluetooth.dart';

final bluetooth = VitalBluetooth();

// 1. Permissions
final status = await bluetooth.requestPermissions();
if (!status.isGranted) return;

// 2. Scan for heart rate monitors
final result = await bluetooth
    .scan(withServices: ['180d'], timeout: const Duration(seconds: 10))
    .first;

// 3. Connect (opens the link and discovers services, with retries)
final device = result.device;
await device.connect();

// 4. Subscribe to heart rate measurements
final heartRate = device.characteristic('180d', '2a37')!;
heartRate.values.listen((bytes) => print('HR packet: $bytes'));
await heartRate.setNotify(true);
```

UUIDs can be written as `'180d'`, `'0x180D'` or the full 128-bit form.

## Staying connected in the background

```dart
final bluetooth = VitalBluetooth();

// Keep reconnecting while the app is open, with no attempt limit.
bluetooth.defaultOptions = const ConnectionOptions(
  reconnect: ReconnectPolicy.unlimited(),
);

// When the app starts: pick up links that were kept alive while it was
// closed, and store what arrived meanwhile.
final devices = await bluetooth.restoreDevices();
final missed = await bluetooth.takeBackgroundValues();
for (final v in missed) {
  saveReading(v.deviceId, v.characteristicUuid, v.value, v.timestamp);
}

// Turn it on while the app is in the foreground.
await bluetooth.enableBackgroundMode(
  title: 'Heart rate monitor',
  text: 'Connected',
);
```

What it does on each platform:

- **Android** runs a foreground service of type `connectedDevice` with an
  ongoing notification (the system requires one). The process is kept
  alive, links outlive the app's screen (back button, swiping the app away
  from recents), and while no screen is open a dropped link is reconnected
  natively with `autoConnect`, with no time limit. Values that arrive with
  no screen open are buffered (the latest 10,000).
- **iOS** suspends apps in the background, so Dart timers stop. A dropped
  link is therefore reconnected natively right away: iOS keeps the connect
  pending and wakes the app when the device is back. With state
  restoration, iOS also relaunches the app in the background for a device
  event after it was terminated for memory. iOS doesn't relaunch an app the
  user swiped away. Restoration starts at the launch after background mode
  was first turned on.
- **macOS** and **Windows** don't suspend apps, so links already live as
  long as the app does.

## Usage

### Adapter and permissions

```dart
ValueListenableBuilder(
  valueListenable: bluetooth.adapterState,
  builder: (context, state, _) => Text(state.isOn ? 'On' : 'Off'),
);

await bluetooth.turnOn(); // Android shows the system prompt
```

### Scanning

`scan()` starts when you listen and stops when you cancel, when the timeout
passes, or when the platform ends it. Only one scan runs at a time; starting
another ends the first.

```dart
final subscription = bluetooth
    .scan(mode: ScanMode.lowLatency, allowDuplicates: true)
    .listen((r) => print('${r.name} ${r.rssi} dBm'));

await subscription.cancel(); // stops the scan
```

### Connection state

```dart
ValueListenableBuilder(
  valueListenable: device.connectionState,
  builder: (context, state, _) => Text(state.status.name),
);
```

Statuses: `disconnected`, `connecting`, `discovering`, `ready`,
`reconnecting`, `disconnecting`.

`bluetooth.device(id)` returns the same object for the same ID, so a screen
can be closed and opened again without losing the connection. Keep devices
in your state-management layer and call `disconnect()` only when the user
asks.

### Reading and writing

```dart
final location = device.characteristic('180d', '2a38')!;
final value = await location.read();

final control = device.characteristic(serviceUuid, controlUuid)!;
await control.write([0x01, 0xA0], withResponse: true);
```

Every value from `valuesWithTime` carries the time the platform received
it, which matters for signals like ECG because values reach Dart in
batches:

```dart
heartRate.valuesWithTime.listen((v) => print('${v.timestamp}: ${v.value}'));
```

### Reconnect and timeouts

```dart
final device = bluetooth.device(
  id,
  options: const ConnectionOptions(
    connectTimeout: Duration(seconds: 15),
    connectAttempts: 3,
    reconnect: ReconnectPolicy.unlimited(),
  ),
);
```

`ReconnectPolicy()` tries 5 times with exponential backoff (1 s up to
30 s). `ReconnectPolicy.none()` turns reconnecting off. Options apply when
a device object is first created; set `bluetooth.defaultOptions` before
scanning to cover devices created from scan results.

### MTU, RSSI, bonding

```dart
await device.requestMtu(247);
final rssi = await device.readRssi();
await device.createBond();
await device.requestConnectionPriority(ConnectionPriority.high);
```

Check `await bluetooth.getCapabilities()` to see what the current platform
supports before offering a feature.

### Errors

All errors extend the sealed `VitalBluetoothException`:

```dart
try {
  await device.connect();
} on VitalBluetoothException catch (e) {
  switch (e) {
    case PermissionDeniedException(:final permanentlyDenied):
      // ask the user, or send them to the settings
    case LocationServicesDisabledException():
      // Android 7–11: ask the user to turn location on
    case GattException(requiresBonding: true):
      await device.createBond();
    case _ when e.isRetryable:
      // try again later
    default:
      print(e); // includes the native code, e.g. GATT status 133
  }
}
```

## Example app

The [example](example) scans for nearby devices, connects, lists services,
lets you read, write (hex) and subscribe to any characteristic, and has a
background-mode switch that shows what arrived while the app was closed.

## License

MIT
