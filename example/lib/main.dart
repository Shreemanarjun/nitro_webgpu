import 'package:flutter/material.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

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

  Future<void> _probeGpu() async {
    setState(() => _result = 'requesting adapter…');
    GpuAdapter? adapter;
    GpuDevice? device;
    try {
      adapter = await Gpu.requestAdapter(
        powerPreference: GpuPowerPreference.highPerformance,
      );
      final info = adapter.info;
      final limits = adapter.limits;
      device = await adapter.requestDevice(label: 'demo-device');
      setState(() {
        _result = 'wgpu-native ${Gpu.version}\n'
            '${info.device} (${adapter!.backendType.name}, '
            '${adapter.adapterType.name})\n'
            'max texture 2D: ${limits.maxTextureDimension2D}\n'
            'max buffer: ${(limits.maxBufferSize / (1 << 20)).toStringAsFixed(0)} MiB\n'
            'device + queue: OK';
      });
    } catch (e) {
      setState(() => _result = 'Error: $e');
    } finally {
      device?.dispose();
      adapter?.dispose();
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_result,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _probeGpu,
              child: const Text('Probe WebGPU adapter'),
            ),
          ],
        ),
      ),
    );
  }
}
