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

  void _initWgpu() {
    setState(() => _result = '—');
    try {
      plugin.NitroWebgpu.instance.initInstance(const plugin.GpuInstanceOptions());
      final version = plugin.NitroWebgpu.instance.wgpuVersion();
      setState(() => _result = 'wgpu-native $version — instance created');
    } catch (e) {
      setState(() => _result = 'Error: $e');
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
            ElevatedButton(
              onPressed: _initWgpu,
              child: const Text('Init WebGPU instance'),
            ),
          ],
        ),
      ),
    );
  }
}
