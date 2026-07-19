// Downlevel-adapter gating: wgpu's GL backend (GLES emulators without
// Vulkan, old Android devices) lacks compute shaders and vertex-stage
// storage buffers. Tests that require them skip with a clear message
// instead of failing — render-path coverage still runs everywhere.
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

/// True when the plugin was built against Dawn (feat/dawn-backend): Dawn
/// has no packed-version query, so the version string reports 0.0.0.0.
bool get isDawnBackend => Gpu.version == '0.0.0.0';

/// The iOS simulator's Metal (Apple2-sim family) has no indirect execution;
/// the plugin refuses indirect calls there with a catchable error (wgpu
/// would otherwise abort the process at submit). Probe by encoding one
/// indirect draw — the refusal throws synchronously at encode time.
bool? _indirectSupport;

Future<bool> _deviceSupportsIndirect(GpuDevice device) async {
  if (_indirectSupport != null) return _indirectSupport!;
  if (!Platform.isIOS) return _indirectSupport = true;
  final tex = device.createTexture(
      width: 1,
      height: 1,
      format: GpuTextureFormat.rgba8Unorm,
      usage: GpuTextureUsage.renderAttachment);
  final buf = device.createBuffer(size: 16, usage: GpuBufferUsage.indirect);
  final encoder = device.createCommandEncoder();
  final pass = encoder.beginRenderPass(colorAttachments: [
    GpuColorAttachmentInfo(view: tex.createView()),
  ]);
  var ok = true;
  try {
    pass.drawIndirect(buf);
  } catch (_) {
    ok = false;
  }
  pass.end();
  // Never submitted — the encoder is abandoned on purpose.
  buf.dispose();
  tex.dispose();
  return _indirectSupport = ok;
}

/// Skips the current test when [device] cannot execute indirect draws
/// (iOS simulator). Returns true when the test should bail out.
Future<bool> skipWithoutIndirect(GpuDevice device) async {
  if (await _deviceSupportsIndirect(device)) return false;
  markTestSkipped(
      'iOS simulator: no indirect execution (Metal Apple2-sim family)');
  return true;
}

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

/// Dawn without a staged glslang build cannot ingest GLSL (the plugin
/// throws a typed error naming glslang). Probe once and skip GLSL tests.
bool? _glslSupport;

Future<bool> skipWithoutGlsl(GpuDevice device) async {
  if (_glslSupport == null) {
    try {
      final module = await device.createShaderModuleGlsl('''
#version 450
layout(location = 0) out vec4 fragColor;
void main() { fragColor = vec4(1.0); }
''', stage: GpuShaderStage.fragment);
      module.dispose();
      _glslSupport = true;
    } catch (e) {
      _glslSupport = !'$e'.contains('glslang');
    }
  }
  if (_glslSupport!) return false;
  markTestSkipped('Dawn backend without a staged glslang: no GLSL front end');
  return true;
}

/// Dawn on Adreno hardware silently draws nothing for CPU-written
/// (writeBuffer) indirect args — Dawn's indirect-validation compute prepass
/// misreads them (GPU-authored args work; SwiftShader is fine on both).
/// Upstream-investigation item; see docs/DAWN_MIGRATION.md.
Future<bool> skipDawnHardwareCpuIndirect(GpuAdapter adapter) async {
  if (!isDawnBackend ||
      !Platform.isAndroid ||
      adapter.info.device.contains('SwiftShader')) {
    return false;
  }
  markTestSkipped(
      'Dawn/Adreno: CPU-written indirect args draw nothing (upstream)');
  return true;
}
