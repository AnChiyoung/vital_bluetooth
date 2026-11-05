## 0.1.1

* Works with older Flutter: the minimum is now Dart 3.7 / Flutter 3.29
  (was Dart 3.13).
* Android: builds in apps that still use Android Gradle Plugin 8.

## 0.1.0

* First release.
* Bluetooth LE on Android, iOS, macOS and Windows: scanning, connecting,
  service discovery, read, write, notifications, descriptors and MTU.
  Android adds RSSI, connection priority, PHY and bonding; Windows adds
  bonding; Apple platforms add RSSI.
* Background mode: links survive the background and the app's screen being
  closed. Dropped links are reconnected natively, notifications are turned
  back on, and values that arrive while no Dart code runs are buffered.
  Android uses a foreground service, iOS state restoration.
* Automatic reconnect with backoff; notifications are restored after every
  reconnect.
* Per-device operation queue with timeouts.
* Sealed, typed error hierarchy.
* `ValueListenable` state for the adapter, scanning, connections, services,
  MTU and device names.
