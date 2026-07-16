// Hardware-adapter guarantee: on machines with a real GPU, requestAdapter
// must never hand back a CPU/software adapter (some Android vendors ship
// SwiftShader as a system Vulkan ICD that can win wgpu's default selection).
//
// Run this on real hardware only — software-only environments (CI runners,
// SwiftShader emulators) legitimately have nothing but CPU adapters.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('requestAdapter picks real GPU hardware over software ICDs', () async {
    final adapter = await Gpu.requestAdapter(
      powerPreference: GpuPowerPreference.highPerformance,
    );
    final info = adapter.info;
    // ignore: avoid_print
    print('[hw-adapter] device=${info.device} vendor=${info.vendor} '
        'backend=${adapter.backendType.name} type=${adapter.adapterType.name}');
    expect(adapter.adapterType, isNot(GpuAdapterType.cpu),
        reason: 'a hardware GPU must win over software adapters '
            '(got ${info.device})');

    // The adapter must actually work end-to-end.
    final device = await adapter.requestDevice();
    final module = await device.createShaderModule('''
@compute @workgroup_size(1) fn main() {}
''');
    final pipeline = await device.createComputePipeline(module: module);
    pipeline.dispose();
    module.dispose();
    device.dispose();
    adapter.dispose();
  });
}
