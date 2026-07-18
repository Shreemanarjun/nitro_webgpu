// Downlevel-adapter gating: wgpu's GL backend (GLES emulators without
// Vulkan, old Android devices) lacks compute shaders and vertex-stage
// storage buffers. Tests that require them skip with a clear message
// instead of failing — render-path coverage still runs everywhere.
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

/// Skips the current test when [device] cannot run compute shaders.
/// Returns true when the test should bail out.
Future<bool> skipWithoutCompute(GpuDevice device) async {
  if (await device.supportsCompute()) return false;
  markTestSkipped('downlevel adapter (GL backend): no compute shaders');
  return true;
}

/// Skips the current test when [device] cannot read storage buffers from
/// the vertex stage (GPU-driven instancing). Returns true when skipped.
Future<bool> skipWithoutVertexStorage(GpuDevice device) async {
  if (await device.supportsCompute() &&
      await device.supportsVertexStorage()) {
    return false;
  }
  markTestSkipped(
      'downlevel adapter (GL backend): no compute / vertex storage');
  return true;
}
