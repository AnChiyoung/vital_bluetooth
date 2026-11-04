import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';

import 'device_page.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'vital_bluetooth example',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const ScanPage(),
    );
  }
}

/// Shows the adapter state, asks for permissions, and lists nearby devices.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _bluetooth = VitalBluetooth();
  final _results = <String, ScanResult>{};
  StreamSubscription<ScanResult>? _scan;
  PermissionStatus? _permission;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  @override
  void dispose() {
    _scan?.cancel();
    super.dispose();
  }

  Future<void> _checkPermission() async {
    try {
      final status = await _bluetooth.permissionStatus();
      if (mounted) setState(() => _permission = status);
    } on VitalBluetoothException catch (e) {
      _showError(e);
    }
  }

  Future<void> _requestPermission() async {
    try {
      final status = await _bluetooth.requestPermissions();
      if (mounted) setState(() => _permission = status);
    } on VitalBluetoothException catch (e) {
      _showError(e);
    }
  }

  Future<void> _turnOn() async {
    try {
      await _bluetooth.turnOn();
    } on VitalBluetoothException catch (e) {
      _showError(e);
    }
  }

  void _toggleScan() {
    if (_scan != null) {
      _scan!.cancel();
      setState(() => _scan = null);
      return;
    }
    setState(() {
      _results.clear();
      _error = null;
      _scan = _bluetooth
          .scan(allowDuplicates: true, timeout: const Duration(seconds: 30))
          .listen(
            (r) => setState(() => _results[r.device.id] = r),
            onError: (Object e) => _showError(e),
            onDone: () {
              if (mounted) setState(() => _scan = null);
            },
          );
    });
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(() => _error = error.toString());
  }

  @override
  Widget build(BuildContext context) {
    final results = _results.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Scaffold(
      appBar: AppBar(title: const Text('vital_bluetooth')),
      body: Column(
        children: [
          ValueListenableBuilder(
            valueListenable: _bluetooth.adapterState,
            builder: (context, state, _) => ListTile(
              leading: Icon(
                state.isOn ? Icons.bluetooth : Icons.bluetooth_disabled,
              ),
              title: Text('Adapter: ${state.name}'),
              trailing: state == AdapterState.poweredOff
                  ? TextButton(onPressed: _turnOn, child: const Text('Turn on'))
                  : null,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.lock_open),
            title: Text('Permission: ${_permission?.name ?? '...'}'),
            trailing: _permission == PermissionStatus.granted
                ? null
                : TextButton(
                    onPressed: _requestPermission,
                    child: const Text('Request'),
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              itemCount: results.length,
              itemBuilder: (context, i) => _ResultTile(results[i]),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleScan,
        icon: Icon(_scan == null ? Icons.search : Icons.stop),
        label: Text(_scan == null ? 'Scan' : 'Stop'),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile(this.result);

  final ScanResult result;

  @override
  Widget build(BuildContext context) {
    final name = result.name;
    return ListTile(
      title: Text(name == null || name.isEmpty ? '(no name)' : name),
      subtitle: Text(result.device.id),
      trailing: Text('${result.rssi} dBm'),
      enabled: result.connectable,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DevicePage(device: result.device, name: name),
        ),
      ),
    );
  }
}
