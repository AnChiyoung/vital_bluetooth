# vital_bluetooth example

Shows what vital_bluetooth does on a real device:

- **Scan screen**: adapter state with a "Turn on" button, permission status
  with a "Request" button, a background-mode switch, devices you opened
  ("My devices", with live connection status) and nearby devices.
- **Device screen**: connect and disconnect, MTU, RSSI and bonding, every
  service and characteristic, with read, hex write and notifications.

Leaving the device screen keeps the connection. With background mode on,
close the app, wait, and open it again: the device is still connected, and
a message says how many values arrived while it was closed.

The code is in [lib/main.dart](lib/main.dart) and
[lib/device_page.dart](lib/device_page.dart).

```bash
flutter run
```
