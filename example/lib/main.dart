import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart' as plugin;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NitroWebgpu Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
      home: const _DemoPage(),
    );
  }
}

class _DemoPage extends StatefulWidget {
  const _DemoPage();
  @override
  State<_DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<_DemoPage> {
  String _result = '—';
  bool _loading = false;

  Future<void> _runAdd() async {
    setState(() { _loading = true; _result = '—'; });
    try {
      final v = plugin.NitroWebgpu.instance.add(3, 4);
      setState(() => _result = 'add(3, 4) = $v');
    } catch (e) {
      setState(() => _result = 'Error: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _runGreeting() async {
    setState(() { _loading = true; _result = '—'; });
    try {
      final s = await plugin.NitroWebgpu.instance.getGreeting('World');
      setState(() => _result = s);
    } catch (e) {
      setState(() => _result = 'Error: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NitroWebgpu Demo')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_result, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            if (_loading) const CircularProgressIndicator(),
            if (!_loading) ...[
              ElevatedButton(onPressed: _runAdd, child: const Text('add(3, 4)')),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _runGreeting, child: const Text('getGreeting("World")')),
            ],
          ],
        ),
      ),
    );
  }
}
