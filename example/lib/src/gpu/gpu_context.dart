import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';
// ignore: implementation_imports
import 'package:nitro_webgpu/src/nitro_webgpu_present.native.dart';

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

  /// The refresh rate the platform granted via `requestMaxRefreshRate` —
  /// more trustworthy than `View.display.refreshRate`, which can keep
  /// reporting the pre-boost default mode.
  static double displayRefreshRate = 0;

  static Future<GpuContext>? _instance;

  static Future<GpuContext> obtain() => _instance ??= _create();

  static Future<GpuContext> _create() async {
    // Ask the platform for its fastest display mode (Android otherwise runs
    // Flutter at the panel default — 60 Hz on many 120 Hz devices). Retries
    // briefly: the activity attaches slightly after startup.
    unawaited(() async {
      for (var i = 0; i < 10; i++) {
        final hz = NitroWebgpuPresent.instance.requestMaxRefreshRate();
        if (hz > 0) {
          displayRefreshRate = hz;
          debugPrint('[gpu] display refresh boosted to ${hz.round()} Hz');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }());
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
