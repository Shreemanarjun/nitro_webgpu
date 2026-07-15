import 'dart:typed_data';

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

  Future<void> _runCompute() async {
    setState(() => _result = 'dispatching compute…');
    GpuAdapter? adapter;
    GpuDevice? device;
    try {
      adapter = await Gpu.requestAdapter();
      device = await adapter.requestDevice();
      final queue = device.queue;

      final storage = device.createBuffer(
        size: 64 * 4,
        usage: GpuBufferUsage.storage |
            GpuBufferUsage.copyDst |
            GpuBufferUsage.copySrc,
      );
      final staging = device.createBuffer(
        size: 64 * 4,
        usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst,
      );
      final input =
          Float32List.fromList(List.generate(64, (i) => (i + 1).toDouble()));
      queue.writeBuffer(storage, input.buffer.asUint8List());

      final module = await device.createShaderModule('''
@group(0) @binding(0) var<storage, read_write> data: array<f32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  data[gid.x] = data[gid.x] * 2.0;
}
''');
      final pipeline = await device.createComputePipeline(module: module);
      final layout = pipeline.getBindGroupLayout(0);
      final bindGroup = device.createBindGroup(layout: layout, entries: [
        GpuBufferBinding(binding: 0, buffer: storage),
      ]);

      final encoder = device.createCommandEncoder();
      final pass = encoder.beginComputePass();
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);
      pass.dispatchWorkgroups(1);
      pass.end();
      encoder.copyBufferToBuffer(storage, staging);
      queue.submit([encoder.finish()]);

      final bytes = await staging.mapRead();
      final out = bytes.buffer.asFloat32List(bytes.offsetInBytes, 64);
      setState(() {
        _result = 'GPU compute: doubled 64 floats\n'
            'in : 1, 2, 3, … 64\n'
            'out: ${out[0].toInt()}, ${out[1].toInt()}, '
            '${out[2].toInt()}, … ${out[63].toInt()}';
      });

      bindGroup.dispose();
      layout.dispose();
      pipeline.dispose();
      module.dispose();
      staging.dispose();
      storage.dispose();
    } catch (e) {
      setState(() => _result = 'Error: $e');
    } finally {
      device?.dispose();
      adapter?.dispose();
    }
  }

  Future<void> _renderTriangle() async {
    setState(() => _result = 'rendering offscreen…');
    GpuAdapter? adapter;
    GpuDevice? device;
    try {
      adapter = await Gpu.requestAdapter();
      device = await adapter.requestDevice();
      final queue = device.queue;

      final module = await device.createShaderModule('''
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  var pos = array<vec2<f32>, 3>(
    vec2(-1.0, -3.0), vec2(3.0, 1.0), vec2(-1.0, 1.0));
  return vec4(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4<f32> {
  return vec4(0.2, 0.8, 0.3, 1.0);
}
''');
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
      );
      final texture = device.createTexture(
        width: 64,
        height: 64,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final view = texture.createView();
      final readback = device.createBuffer(
        size: 64 * 64 * 4,
        usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst,
      );

      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(view: view, clearColor: GpuColor.black),
      ]);
      pass.setPipeline(pipeline);
      pass.draw(3);
      pass.end();
      encoder.copyTextureToBuffer(texture, readback);
      queue.submit([encoder.finish()]);

      final pixels = await readback.mapRead();
      final c = ((32 * 64) + 32) * 4;
      setState(() {
        _result = 'offscreen render: 64×64 fullscreen triangle\n'
            'center pixel rgba: '
            '${pixels[c]}, ${pixels[c + 1]}, ${pixels[c + 2]}, ${pixels[c + 3]}';
      });

      readback.dispose();
      view.dispose();
      texture.dispose();
      pipeline.dispose();
      module.dispose();
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
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton(
                    onPressed: _probeGpu, child: const Text('Probe adapter')),
                ElevatedButton(
                    onPressed: _runCompute, child: const Text('Run compute')),
                ElevatedButton(
                    onPressed: _renderTriangle,
                    child: const Text('Render offscreen')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
