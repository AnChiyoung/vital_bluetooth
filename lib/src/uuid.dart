/// Helpers for Bluetooth UUIDs.
abstract final class BluetoothUuid {
  static const _baseSuffix = '-0000-1000-8000-00805f9b34fb';
  static final _full = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static final _short = RegExp(r'^[0-9a-f]{4}$|^[0-9a-f]{8}$');

  /// Turns a UUID into the lowercase 128-bit form every platform uses.
  ///
  /// Accepts the short forms from the Bluetooth specifications, so `'180D'`
  /// and `'0x180d'` both become `'0000180d-0000-1000-8000-00805f9b34fb'`.
  /// Throws a [FormatException] for anything else.
  static String normalize(String uuid) {
    var value = uuid.trim().toLowerCase();
    if (value.startsWith('0x')) value = value.substring(2);
    if (_full.hasMatch(value)) return value;
    if (_short.hasMatch(value)) {
      return '${value.padLeft(8, '0')}$_baseSuffix';
    }
    throw FormatException('Not a Bluetooth UUID', uuid);
  }

  /// Whether [a] and [b] name the same UUID, in any accepted form.
  static bool equals(String a, String b) => normalize(a) == normalize(b);
}
