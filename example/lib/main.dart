import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _bluetooth = VitalBluetooth();
  String _status = 'Checking...';

  @override
  void initState() {
    super.initState();
    _loadCapabilities();
  }

  Future<void> _loadCapabilities() async {
    String status;
    try {
      final caps = await _bluetooth.getCapabilities();
      status = 'BLE: ${caps.ble}\nClassic: ${caps.classic}';
    } on PlatformException catch (e) {
      status = 'Failed: ${e.message}';
    }
    if (!mounted) return;
    setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('vital_bluetooth example')),
        body: Center(child: Text(_status)),
      ),
    );
  }
}
