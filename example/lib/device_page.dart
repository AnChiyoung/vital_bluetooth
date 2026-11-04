import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';

/// Connects to one device and lets you try its characteristics.
class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.device, this.name});

  final BluetoothDevice device;
  final String? name;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  BluetoothDevice get _device => widget.device;
  String? _message;

  @override
  void dispose() {
    // Leaving the page ends the connection.
    unawaited(_device.disconnect());
    super.dispose();
  }

  Future<void> _try(String label, Future<Object?> Function() action) async {
    try {
      final result = await action();
      _say(result == null ? '$label: done' : '$label: $result');
    } on VitalBluetoothException catch (e) {
      _say('$label failed: $e');
    }
  }

  void _say(String message) {
    if (mounted) setState(() => _message = message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name ?? _device.id)),
      body: ValueListenableBuilder(
        valueListenable: _device.connectionState,
        builder: (context, state, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text('State: ${state.status.name}'),
              subtitle: state.error == null
                  ? null
                  : Text(state.error.toString(), maxLines: 3),
              trailing: _ConnectButton(
                device: _device,
                state: state,
                onTry: _try,
              ),
            ),
            if (state.isReady)
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => _try('MTU', () => _device.requestMtu(247)),
                    child: const Text('MTU 247'),
                  ),
                  OutlinedButton(
                    onPressed: () => _try('RSSI', _device.readRssi),
                    child: const Text('RSSI'),
                  ),
                  OutlinedButton(
                    onPressed: () => _try('Bond', _device.createBond),
                    child: const Text('Bond'),
                  ),
                ],
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_message!),
              ),
            const Divider(),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: _device.services,
                builder: (context, services, _) => ListView(
                  children: [
                    for (final service in services)
                      ExpansionTile(
                        title: Text(_shortUuid(service.uuid)),
                        subtitle: Text(service.uuid),
                        children: [
                          for (final c in service.characteristics)
                            _CharacteristicTile(c, onTry: _try),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectButton extends StatelessWidget {
  const _ConnectButton({
    required this.device,
    required this.state,
    required this.onTry,
  });

  final BluetoothDevice device;
  final DeviceConnectionState state;
  final Future<void> Function(String, Future<Object?> Function()) onTry;

  @override
  Widget build(BuildContext context) {
    final idle = state.status == DeviceConnectionStatus.disconnected;
    return FilledButton(
      onPressed: () => idle
          ? onTry('Connect', device.connect)
          : onTry('Disconnect', device.disconnect),
      child: Text(idle ? 'Connect' : 'Disconnect'),
    );
  }
}

class _CharacteristicTile extends StatefulWidget {
  const _CharacteristicTile(this.characteristic, {required this.onTry});

  final BluetoothCharacteristic characteristic;
  final Future<void> Function(String, Future<Object?> Function()) onTry;

  @override
  State<_CharacteristicTile> createState() => _CharacteristicTileState();
}

class _CharacteristicTileState extends State<_CharacteristicTile> {
  StreamSubscription<List<int>>? _values;
  String? _last;
  int _count = 0;

  BluetoothCharacteristic get _c => widget.characteristic;

  @override
  void dispose() {
    _values?.cancel();
    super.dispose();
  }

  Future<void> _toggleNotify() async {
    final enable = !_c.isNotifying;
    if (enable) {
      _values ??= _c.values.listen(
        (v) => setState(() {
          _last = _hex(v);
          _count++;
        }),
      );
    }
    await widget.onTry(
      'Notify ${enable ? 'on' : 'off'}',
      () => _c.setNotify(enable),
    );
    if (mounted) setState(() {});
  }

  Future<void> _write() async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) =>
          _HexDialog(title: 'Write to ${_shortUuid(_c.uuid)}'),
    );
    if (text == null) return;
    final bytes = _parseHex(text);
    if (bytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Not hex: $text')));
      }
      return;
    }
    await widget.onTry(
      'Write',
      () => _c.write(bytes, withResponse: _c.properties.write),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _c.properties;
    return ListTile(
      title: Text(_shortUuid(_c.uuid)),
      subtitle: Text(
        [
          p.toString(),
          if (_last != null) 'last: $_last ($_count received)',
        ].join('\n'),
      ),
      isThreeLine: _last != null,
      trailing: Wrap(
        children: [
          if (p.read)
            IconButton(
              tooltip: 'Read',
              icon: const Icon(Icons.download),
              onPressed: () =>
                  widget.onTry('Read', () async => _hex(await _c.read())),
            ),
          if (p.write || p.writeWithoutResponse)
            IconButton(
              tooltip: 'Write',
              icon: const Icon(Icons.upload),
              onPressed: _write,
            ),
          if (p.canSubscribe)
            IconButton(
              tooltip: 'Notify',
              icon: Icon(
                _c.isNotifying
                    ? Icons.notifications_active
                    : Icons.notifications_none,
              ),
              onPressed: _toggleNotify,
            ),
        ],
      ),
    );
  }
}

class _HexDialog extends StatefulWidget {
  const _HexDialog({required this.title});

  final String title;

  @override
  State<_HexDialog> createState() => _HexDialogState();
}

class _HexDialogState extends State<_HexDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Hex, e.g. 01 a0 ff'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Write'),
        ),
      ],
    );
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

List<int>? _parseHex(String text) {
  final clean = text.replaceAll(RegExp(r'[\s:,]'), '');
  if (clean.isEmpty || clean.length.isOdd) return null;
  final bytes = <int>[];
  for (var i = 0; i < clean.length; i += 2) {
    final byte = int.tryParse(clean.substring(i, i + 2), radix: 16);
    if (byte == null) return null;
    bytes.add(byte);
  }
  return bytes;
}

/// Shows "0x180d" for UUIDs on the Bluetooth base UUID.
String _shortUuid(String uuid) =>
    uuid.endsWith('-0000-1000-8000-00805f9b34fb') && uuid.startsWith('0000')
    ? '0x${uuid.substring(4, 8)}'
    : uuid;
