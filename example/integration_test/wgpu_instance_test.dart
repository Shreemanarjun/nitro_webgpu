import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('M0 link proof', () {
    test('wgpuVersion returns the pinned wgpu-native version', () {
      final version = NitroWebgpu.instance.wgpuVersion();
      expect(version, '29.0.1.1');
    });

    test('initInstance creates the WGPUInstance and is idempotent', () {
      const options = GpuInstanceOptions();
      NitroWebgpu.instance.initInstance(options);
      // Second call must be a no-op, not a crash or a second instance.
      NitroWebgpu.instance.initInstance(options);
    });
  });
}
