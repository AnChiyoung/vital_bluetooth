/// A single request sent to a remote device.
///
/// Used to tag queued work, timeouts and errors so callers can tell which
/// step of a flow failed.
enum BluetoothOperation {
  connect,
  disconnect,
  discoverServices,
  read,
  write,
  writeWithoutResponse,
  setNotify,
  readDescriptor,
  writeDescriptor,
  requestMtu,
  requestConnectionPriority,
  setPreferredPhy,
  readRssi,
  bond,
  removeBond,
  classicWrite,
}
