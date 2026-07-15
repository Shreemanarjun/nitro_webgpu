import 'package:flutter/material.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

import '../gpu/gpu_context.dart';

/// Shows the adapter identity, backend, and key limits.
class AdapterProbePage extends StatefulWidget {
  const AdapterProbePage({super.key});

  @override
  State<AdapterProbePage> createState() => _AdapterProbePageState();
}

class _AdapterProbePageState extends State<AdapterProbePage> {
  List<(String, String)>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    try {
      final ctx = await GpuContext.obtain();
      final info = ctx.adapter.info;
      final limits = ctx.adapter.limits;
      setState(() {
        _rows = [
          ('wgpu-native', Gpu.version),
          ('Device', info.device),
          ('Vendor', info.vendor.isEmpty ? '—' : info.vendor),
          ('Backend', ctx.adapter.backendType.name),
          ('Adapter type', ctx.adapter.adapterType.name),
          ('Max texture 2D', '${limits.maxTextureDimension2D} px'),
          ('Max buffer', '${limits.maxBufferSize >> 20} MiB'),
          ('Max bind groups', '${limits.maxBindGroups}'),
          (
            'Max workgroup size',
            '${limits.maxComputeWorkgroupSizeX}×'
                '${limits.maxComputeWorkgroupSizeY}×'
                '${limits.maxComputeWorkgroupSizeZ}'
          ),
          (
            'Uniform alignment',
            '${limits.minUniformBufferOffsetAlignment} B'
          ),
        ];
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Adapter probe')),
      body: _error != null
          ? Center(child: Text('Error: $_error'))
          : _rows == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final (label, value) in _rows!)
                      ListTile(
                        dense: true,
                        title: Text(label),
                        trailing: Text(
                          value,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                  ],
                ),
    );
  }
}
