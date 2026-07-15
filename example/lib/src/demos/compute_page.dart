import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

import '../gpu/gpu_context.dart';

/// Runs the canonical compute demo: a WGSL kernel doubles 64 floats on the
/// GPU, read back over a staging buffer.
class ComputePage extends StatefulWidget {
  const ComputePage({super.key});

  @override
  State<ComputePage> createState() => _ComputePageState();
}

class _ComputePageState extends State<ComputePage> {
  String _result = 'Press run to dispatch the kernel.';
  bool _running = false;

  static const _wgsl = '''
@group(0) @binding(0) var<storage, read_write> data: array<f32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  data[gid.x] = data[gid.x] * 2.0;
}
''';

  Future<void> _run() async {
    setState(() {
      _running = true;
      _result = 'dispatching…';
    });
    GpuBuffer? storage, staging;
    GpuShaderModule? module;
    GpuComputePipeline? pipeline;
    GpuBindGroupLayout? layout;
    GpuBindGroup? bindGroup;
    try {
      final device = (await GpuContext.obtain()).device;
      final queue = device.queue;

      storage = device.createBuffer(
        size: 64 * 4,
        usage: GpuBufferUsage.storage |
            GpuBufferUsage.copyDst |
            GpuBufferUsage.copySrc,
      );
      staging = device.createBuffer(
        size: 64 * 4,
        usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst,
      );
      final input =
          Float32List.fromList(List.generate(64, (i) => (i + 1).toDouble()));
      queue.writeBuffer(storage, input.buffer.asUint8List());

      module = await device.createShaderModule(_wgsl);
      pipeline = await device.createComputePipeline(module: module);
      layout = pipeline.getBindGroupLayout(0);
      bindGroup = device.createBindGroup(layout: layout, entries: [
        GpuBufferBinding(binding: 0, buffer: storage),
      ]);

      final sw = Stopwatch()..start();
      final encoder = device.createCommandEncoder();
      final pass = encoder.beginComputePass();
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);
      pass.dispatchWorkgroups(1);
      pass.end();
      encoder.copyBufferToBuffer(storage, staging);
      queue.submit([encoder.finish()]);
      final bytes = await staging.mapRead();
      sw.stop();

      final out = bytes.buffer.asFloat32List(bytes.offsetInBytes, 64);
      setState(() {
        _result = 'in : 1, 2, 3 … 64\n'
            'out: ${out[0].toInt()}, ${out[1].toInt()}, '
            '${out[2].toInt()} … ${out[63].toInt()}\n'
            'dispatch + readback: ${sw.elapsedMicroseconds} µs';
      });
    } catch (e) {
      setState(() => _result = 'Error: $e');
    } finally {
      bindGroup?.dispose();
      layout?.dispose();
      pipeline?.dispose();
      module?.dispose();
      staging?.dispose();
      storage?.dispose();
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Compute — double 64 floats')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _result,
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _running ? null : _run,
              child: const Text('Run compute'),
            ),
          ],
        ),
      ),
    );
  }
}
