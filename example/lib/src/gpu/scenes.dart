import 'dart:typed_data';

import 'package:nitro_webgpu/nitro_webgpu.dart';

/// A self-contained animated scene rendered into a [GpuRenderTarget].
///
/// Scenes own their GPU resources (shader module, pipeline, uniforms) and are
/// created per view — construct a fresh instance for every [GpuSceneView].
abstract class GpuScene {
  String get name;

  /// Renders one frame. Called by the view's frame loop; may await pipeline
  /// creation on the first frame. When [timestamps] is non-null the scene
  /// should attach it to its main pass so the view can measure GPU time.
  Future<void> render(GpuDevice device, GpuRenderTarget target,
      Duration elapsed, {GpuTimestampWrites? timestamps});

  void dispose();
}

/// Base for single-pipeline scenes driven by a 16-byte uniform block
/// `{ time, width, height, param }`.
abstract class UniformScene implements GpuScene {
  bool _disposed = false;
  GpuDevice? _device;
  GpuShaderModule? _module;
  GpuBuffer? _uniforms;
  GpuRenderPipeline? _pipeline;
  GpuBindGroupLayout? _layout;
  GpuBindGroup? _bindGroup;
  GpuTextureFormat? _format;

  /// WGSL source. Must declare `struct U { time: f32, width: f32,
  /// height: f32, param: f32 }` bound at `@group(0) @binding(0)` and use
  /// `vs_main` / `fs_main` entry points.
  String get wgsl;

  /// Extra scene parameter passed in the uniform block's `param` slot.
  double get param => 0;

  GpuColor get clearColor => const GpuColor(0.07, 0.07, 0.10);

  Future<void> _ensureResources(GpuDevice device, GpuTextureFormat format) async {
    if (_pipeline != null && _format == format && _device == device) return;
    _disposePipeline();
    _device = device;
    _module ??= await device.createShaderModule(wgsl, label: name);
    _uniforms ??= device.createBuffer(
      size: 16,
      usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst,
      label: '$name-uniforms',
    );
    _pipeline = await device.createRenderPipeline(
      module: _module!,
      targetFormat: format,
      label: name,
    );
    _format = format;
    _layout = _pipeline!.getBindGroupLayout(0);
    _bindGroup = device.createBindGroup(layout: _layout!, entries: [
      GpuBufferBinding(binding: 0, buffer: _uniforms!),
    ]);
  }

  @override
  Future<void> render(GpuDevice device, GpuRenderTarget target,
      Duration elapsed, {GpuTimestampWrites? timestamps}) async {
    // A frame may still be in flight when the owning view unmounts.
    if (_disposed) return;
    await _ensureResources(device, target.targetFormat);
    if (_disposed) return;
    final t = elapsed.inMicroseconds / 1e6;
    device.queue.writeBuffer(
      _uniforms!,
      Float32List.fromList(
        [t, target.width.toDouble(), target.height.toDouble(), param],
      ).buffer.asUint8List(),
    );
    final encoder = device.createCommandEncoder(label: name);
    final pass = encoder.beginRenderPass(colorAttachments: [
      GpuColorAttachmentInfo(view: target.view, clearColor: clearColor),
    ], timestampWrites: timestamps);
    pass.setPipeline(_pipeline!);
    pass.setBindGroup(0, _bindGroup!);
    pass.draw(3);
    pass.end();
    device.queue.submit([encoder.finish()]);
  }

  void _disposePipeline() {
    _bindGroup?.dispose();
    _layout?.dispose();
    _pipeline?.dispose();
    _bindGroup = null;
    _layout = null;
    _pipeline = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _disposePipeline();
    _uniforms?.dispose();
    _module?.dispose();
    _uniforms = null;
    _module = null;
  }
}

/// A triangle spinning around the center; `param` scales the spin speed.
class SpinningTriangleScene extends UniformScene {
  SpinningTriangleScene({this.speed = 1.0});

  final double speed;

  @override
  String get name => 'spinning-triangle';

  @override
  double get param => speed;

  @override
  String get wgsl => '''
struct U { time: f32, width: f32, height: f32, param: f32 };
@group(0) @binding(0) var<uniform> u: U;

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  var pos = array<vec2<f32>, 3>(
    vec2(0.0, 0.7), vec2(-0.7, -0.7), vec2(0.7, -0.7));
  let a = u.time * u.param * 1.5707963;
  let c = cos(a);
  let s = sin(a);
  let p = pos[i];
  let aspect = u.width / max(u.height, 1.0);
  return vec4((c * p.x - s * p.y) / aspect, s * p.x + c * p.y, 0.0, 1.0);
}
@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
  let uv = frag.xy / vec2(u.width, u.height);
  return vec4(0.2 + 0.6 * uv.x, 0.9 - 0.5 * uv.y, 0.4, 1.0);
}
''';
}

/// Classic plasma field — a fullscreen fragment effect.
class PlasmaScene extends UniformScene {
  @override
  String get name => 'plasma';

  @override
  String get wgsl => '''
struct U { time: f32, width: f32, height: f32, param: f32 };
@group(0) @binding(0) var<uniform> u: U;

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  var pos = array<vec2<f32>, 3>(
    vec2(-1.0, -3.0), vec2(3.0, 1.0), vec2(-1.0, 1.0));
  return vec4(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
  let uv = frag.xy / vec2(u.width, u.height);
  let p = uv * 6.0;
  let t = u.time;
  var v = sin(p.x + t);
  v += sin((p.y + t) * 0.5);
  v += sin((p.x + p.y + t) * 0.5);
  v += sin(sqrt(p.x * p.x + p.y * p.y + 1.0) + t * 1.3);
  let r = 0.5 + 0.5 * sin(v * 3.14159);
  let g = 0.5 + 0.5 * sin(v * 3.14159 + 2.0944);
  let b = 0.5 + 0.5 * sin(v * 3.14159 + 4.1888);
  return vec4(r, g, b, 1.0);
}
''';
}

/// Concentric rings radiating from the center.
class RingsScene extends UniformScene {
  @override
  String get name => 'rings';

  @override
  String get wgsl => '''
struct U { time: f32, width: f32, height: f32, param: f32 };
@group(0) @binding(0) var<uniform> u: U;

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  var pos = array<vec2<f32>, 3>(
    vec2(-1.0, -3.0), vec2(3.0, 1.0), vec2(-1.0, 1.0));
  return vec4(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
  let aspect = u.width / max(u.height, 1.0);
  var c = frag.xy / vec2(u.width, u.height) - vec2(0.5);
  c.x *= aspect;
  let d = length(c) * 9.0 - u.time * 2.0;
  let ring = 0.5 + 0.5 * sin(d * 6.28318);
  let glow = 1.0 - smoothstep(0.0, 0.55, length(c));
  return vec4(ring * 0.25 + glow * 0.2, ring * 0.6, 0.95 - ring * 0.4, 1.0);
}
''';
}

/// Bouncing gradient bars — cheap but obviously animated.
class BarsScene extends UniformScene {
  @override
  String get name => 'bars';

  @override
  String get wgsl => '''
struct U { time: f32, width: f32, height: f32, param: f32 };
@group(0) @binding(0) var<uniform> u: U;

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  var pos = array<vec2<f32>, 3>(
    vec2(-1.0, -3.0), vec2(3.0, 1.0), vec2(-1.0, 1.0));
  return vec4(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
  let uv = frag.xy / vec2(u.width, u.height);
  let n = 14.0;
  let lane = floor(uv.x * n);
  let phase = u.time * 1.8 + lane * 0.55;
  let level = 0.5 + 0.45 * sin(phase);
  let lit = step(1.0 - uv.y, level);
  let hue = lane / n;
  return vec4(lit * (0.3 + 0.7 * hue), lit * (0.9 - 0.5 * hue), lit * 0.55,
              1.0);
}
''';
}
