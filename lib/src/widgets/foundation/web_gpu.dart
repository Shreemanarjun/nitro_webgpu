import '../../api/gpu.dart';

/// App-lifetime shared GPU context so simple apps never manage
/// adapter/device lifecycles by hand. The device is created on first use
/// and lives until process exit — the right default for UI apps, where a
/// single device serves every view.
///
/// Apps that need explicit control (multiple devices, custom features or
/// limits, deterministic teardown) keep using [Gpu.requestAdapter] +
/// [GpuAdapter.requestDevice] directly.
abstract final class WebGpu {
  static Future<GpuDevice>? _device;

  /// The shared device, created on first call.
  static Future<GpuDevice> device() => _device ??= _create();

  static Future<GpuDevice> _create() async {
    final adapter = await Gpu.requestAdapter();
    return adapter.requestDevice(label: 'nitro_webgpu-shared-device');
  }
}
