import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

// CI runners have no real GPU; --dart-define=WGPU_FORCE_FALLBACK=true selects
// a software adapter (lavapipe / WARP).
const bool kForceFallback = bool.fromEnvironment('WGPU_FORCE_FALLBACK');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('M0 link proof', () {
    test('wgpuVersion returns the pinned wgpu-native version', () {
      expect(Gpu.version, '29.0.1.1');
    });

    test('ensureInitialized is idempotent', () {
      Gpu.ensureInitialized();
      Gpu.ensureInitialized();
    });
  });

  group('M1a adapter/device', () {
    test('requestAdapter resolves with real adapter info', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final info = adapter.info;
      expect(info.device, isNotEmpty);
      expect(adapter.backendType, isNot(GpuBackendType.undefined));
      expect(adapter.adapterType, isA<GpuAdapterType>());

      final limits = adapter.limits;
      expect(limits.maxTextureDimension2D, greaterThanOrEqualTo(2048));
      expect(limits.maxBufferSize, greaterThan(0));
      adapter.dispose();
    });

    test('requestDevice resolves and provides a queue', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice(label: 'test-device');
      expect(device.queue, isNotNull);
      device.dispose();
      adapter.dispose();
    });

    test('adapter use after dispose throws StateError', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      adapter.dispose();
      adapter.dispose(); // double dispose is a no-op
      expect(() => adapter.info, throwsStateError);
      expect(() => adapter.requestDevice(), throwsStateError);
    });
  });

  group('M1a error handling', () {
    test('clean error scope pops null', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      device.pushErrorScope(GpuErrorFilter.validation);
      final error = await device.popErrorScope();
      expect(error, isNull);
      device.dispose();
      adapter.dispose();
    });

    test('popErrorScope on empty stack rejects', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      await expectLater(device.popErrorScope(), throwsA(anything));
      device.dispose();
      adapter.dispose();
    });

    test('device.destroy() fires onLost with reason destroyed', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final lost = device.onLost.first;
      device.destroy();
      final event = await lost.timeout(const Duration(seconds: 10));
      expect(event.reason, GpuDeviceLostReason.destroyed);
      device.dispose();
      adapter.dispose();
    });
  });

  group('M1a lifecycle stress', () {
    test('repeated adapter/device create+dispose stays stable', () async {
      for (var i = 0; i < 25; i++) {
        final adapter =
            await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
        final device = await adapter.requestDevice();
        device.queue; // touch the queue so it is created and released too
        device.dispose();
        adapter.dispose();
      }
    });
  });
}
