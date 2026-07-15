import 'package:nitro_webgpu/nitro_webgpu.dart';

/// App-wide GPU bootstrap: one adapter + device shared by every demo.
///
/// Multiple [WebGpuView]s can present from the same device simultaneously —
/// each view owns its own presenter, and the plugin refcounts the device on
/// its callback pump. The context lives for the app's lifetime.
class GpuContext {
  GpuContext._(this.adapter, this.device);

  final GpuAdapter adapter;
  final GpuDevice device;

  GpuQueue get queue => device.queue;

  static Future<GpuContext>? _instance;

  static Future<GpuContext> obtain() => _instance ??= _create();

  static Future<GpuContext> _create() async {
    final adapter = await Gpu.requestAdapter(
      powerPreference: GpuPowerPreference.highPerformance,
    );
    final device = await adapter.requestDevice(
      label: 'example-shared-device',
      // Enables real on-GPU pass timing in the perf overlays.
      requireTimestampQueries: adapter.supportsTimestampQueries,
    );
    return GpuContext._(adapter, device);
  }
}
