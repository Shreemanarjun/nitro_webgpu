import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

import 'scenes.dart';

/// Default simulation kernel — editable in the particles page. The contract
/// is fixed: `Particle {pos, vel}` storage at `@binding(1)`, `SimParams`
/// uniforms at `@binding(0)`, entry point `simulate`.
const defaultParticleKernel = '''
struct Particle { pos: vec2f, vel: vec2f };
struct SimParams { dt: f32, time: f32, count: f32, size: f32 };
@group(0) @binding(0) var<uniform> params: SimParams;
@group(0) @binding(1) var<storage, read_write> particles: array<Particle>;

@compute @workgroup_size(64)
fn simulate(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i >= u32(params.count)) { return; }
  var p = particles[i];
  // A gentle swirl toward the center plus wall bounces.
  let toCenter = -p.pos;
  p.vel += (toCenter + vec2f(-toCenter.y, toCenter.x)) * 0.15 * params.dt;
  p.pos += p.vel * params.dt;
  if (abs(p.pos.x) > 1.0) { p.vel.x = -p.vel.x; p.pos.x = clamp(p.pos.x, -1.0, 1.0); }
  if (abs(p.pos.y) > 1.0) { p.vel.y = -p.vel.y; p.pos.y = clamp(p.pos.y, -1.0, 1.0); }
  particles[i] = p;
}
''';

// The particle buffer feeds the render pass as an INSTANCE-STEPPED VERTEX
// BUFFER, not a storage binding: vertex-stage storage buffers are a
// downlevel flag that GL-backend devices (GLES phones, emulators without
// Vulkan) usually lack, while instance attributes work everywhere. The
// compute kernel still writes the same buffer as storage.
const _renderWgsl = '''
struct SimParams { dt: f32, time: f32, count: f32, size: f32 };
@group(0) @binding(0) var<uniform> params: SimParams;

struct VOut {
  @builtin(position) pos: vec4f,
  @location(0) local: vec2f,
  @location(1) speed: f32,
};

@vertex
fn vs_main(@builtin(vertex_index) v: u32,
           @location(0) ppos: vec2f,
           @location(1) pvel: vec2f) -> VOut {
  var corners = array<vec2f, 6>(
      vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(-1.0, 1.0),
      vec2f(-1.0, 1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0));
  let corner = corners[v];
  var o: VOut;
  o.pos = vec4f(ppos + corner * params.size, 0.0, 1.0);
  o.local = corner;
  o.speed = length(pvel);
  return o;
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4f {
  let d2 = dot(in.local, in.local);
  if (d2 > 1.0) { discard; }
  let glow = 1.0 - d2;
  return vec4f(glow, glow * min(in.speed * 0.5 + 0.2, 1.0) * 0.6,
               glow * 0.9, 1.0);
}
''';

/// GPU-driven particle system: a compute pass integrates a storage buffer of
/// `{pos, vel}` particles each frame, then an instanced render pass draws
/// one soft quad per particle straight from that buffer — positions never
/// touch the CPU.
///
/// The simulation kernel hot-swaps through the checked create; on a naga
/// error the previous kernel keeps running and the diagnostics land on
/// [compileError].
class ParticleScene implements GpuScene {
  ParticleScene({
    this.count = 20000,
    this.pointSize = 0.006,
    Float32List? initialParticles,
  }) : _initial = initialParticles;

  @override
  String get name => 'particles';

  final int count;
  final double pointSize;
  final Float32List? _initial;

  double timeScale = 1.0;
  bool paused = false;

  final ValueNotifier<String?> compileError = ValueNotifier(null);

  String? _pendingKernel = defaultParticleKernel;
  String? _activeKernel;
  bool _disposed = false;

  GpuDevice? _device;
  GpuBuffer? _particles;
  GpuBuffer? _uniforms;
  GpuBindGroupLayout? _computeBindLayout;
  GpuPipelineLayout? _computePipelineLayout;
  GpuShaderModule? _computeModule;
  GpuComputePipeline? _computePipeline;
  GpuBindGroup? _computeBind;
  GpuShaderModule? _renderModule;
  GpuRenderPipeline? _renderPipeline;
  GpuTextureFormat? _renderFormat;
  GpuBindGroupLayout? _renderLayout;
  GpuBindGroup? _renderBind;

  double _accum = 0;
  Duration? _lastElapsed;

  // CPU-simulation fallback for adapters without compute shaders (GL
  // backend on some devices): the default swirl physics integrate on the
  // CPU and upload each frame. Custom kernels still require compute.
  bool? _computeAvailable;
  Float32List? _cpuParticles;

  /// The live particle storage buffer (for tests/readback); usage includes
  /// copySrc so it can be copied out.
  GpuBuffer? get particleBuffer => _particles;

  /// Queues a new simulation kernel; compiles on the next frame.
  void setKernel(String source) => _pendingKernel = source;

  Float32List _seedParticles() {
    if (_initial != null) return _initial;
    final rng = math.Random(42);
    final data = Float32List(count * 4);
    for (var i = 0; i < count; i++) {
      data[i * 4 + 0] = rng.nextDouble() * 2 - 1;
      data[i * 4 + 1] = rng.nextDouble() * 2 - 1;
      data[i * 4 + 2] = (rng.nextDouble() * 2 - 1) * 0.3;
      data[i * 4 + 3] = (rng.nextDouble() * 2 - 1) * 0.3;
    }
    return data;
  }

  Future<void> _ensureResources(
      GpuDevice device, GpuTextureFormat format) async {
    _device = device;
    if (_particles == null) {
      final seed = _seedParticles();
      _particles = device.createBuffer(
        size: seed.lengthInBytes,
        usage: GpuBufferUsage.storage |
            GpuBufferUsage.vertex |
            GpuBufferUsage.copyDst |
            GpuBufferUsage.copySrc,
        label: '$name-particles',
      );
      device.queue.writeBuffer(_particles!, seed.buffer.asUint8List());
    }
    _uniforms ??= device.createBuffer(
        size: 16,
        usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst,
        label: '$name-uniforms');
    // Explicit layout: a pasted kernel that ignores a binding would make the
    // auto layout drop it — and getBindGroupLayout on a group the pipeline
    // doesn't have panics natively. The fixed layout keeps any
    // contract-shaped kernel bindable.
    _computeBindLayout ??= device.createBindGroupLayout(entries: const [
      GpuLayoutEntry(
          binding: 0,
          visibility: GpuShaderStage.compute,
          type: GpuBindingType.uniformBuffer),
      GpuLayoutEntry(
          binding: 1,
          visibility: GpuShaderStage.compute,
          type: GpuBindingType.storageBuffer),
    ]);
    _computePipelineLayout ??=
        device.createPipelineLayout(layouts: [_computeBindLayout!]);
    if (_renderPipeline == null || _renderFormat != format) {
      // Downlevel GL adapters reject vertex-stage storage buffers — surface
      // that through compileError (like kernel errors) instead of letting
      // the exception escape the frame callback.
      try {
        _renderModule ??= await device.createShaderModule(_renderWgsl);
        _renderBind?.dispose();
        _renderBind = null;
        _renderLayout?.dispose();
        _renderPipeline?.dispose();
        _renderPipeline = null;
        _renderPipeline = await device.createRenderPipeline(
          module: _renderModule!,
          targetFormat: format,
          vertexBuffers: const [
            GpuVertexLayout(
              arrayStride: 16, // {pos: vec2f, vel: vec2f}
              stepMode: GpuVertexStepMode.instance,
              attributes: [
                GpuVertexAttr(
                    format: GpuVertexFormat.float32x2,
                    offset: 0,
                    shaderLocation: 0),
                GpuVertexAttr(
                    format: GpuVertexFormat.float32x2,
                    offset: 8,
                    shaderLocation: 1),
              ],
            ),
          ],
          label: '$name-render',
        );
      } catch (e) {
        if (!_disposed) {
          compileError.value = e is GpuValidationException ? e.message : '$e';
        }
        return;
      }
      _renderFormat = format;
      _renderLayout = _renderPipeline!.getBindGroupLayout(0);
    }
    _renderBind ??= device.createBindGroup(layout: _renderLayout!, entries: [
      GpuBufferBinding(binding: 0, buffer: _uniforms!),
    ]);
  }

  Future<void> _trySwapKernel(GpuDevice device) async {
    final source = _pendingKernel ?? _activeKernel;
    _pendingKernel = null;
    if (source == null) return;
    _computeAvailable ??= await device.supportsCompute();
    if (_computeAvailable == false) {
      // No compute on this adapter: the built-in CPU simulation drives the
      // default physics; custom kernels can't run.
      if (!_disposed) {
        compileError.value = source == defaultParticleKernel
            ? null
            : 'Compute shaders are unavailable on this adapter (GL '
                'backend) — running the built-in CPU simulation instead. '
                'Custom kernels need a Vulkan/Metal-backed device.';
      }
      return;
    }
    GpuShaderModule? module;
    GpuComputePipeline? pipeline;
    try {
      module = await device.createShaderModule(source, label: '$name-sim');
      pipeline = await device.createComputePipeline(
          module: module,
          entryPoint: 'simulate',
          layout: _computePipelineLayout,
          label: '$name-sim');
    } catch (e) {
      pipeline?.dispose();
      module?.dispose();
      if (!_disposed) {
        compileError.value = e is GpuValidationException ? e.message : '$e';
      }
      return;
    }
    if (_disposed) {
      pipeline.dispose();
      module.dispose();
      return;
    }
    _computePipeline?.dispose();
    _computeModule?.dispose();
    _computeModule = module;
    _computePipeline = pipeline;
    _activeKernel = source;
    compileError.value = null;
  }

  @override
  Future<void> render(GpuDevice device, GpuRenderTarget target,
      Duration elapsed, {GpuTimestampWrites? timestamps}) async {
    if (_disposed) return;
    final last = _lastElapsed ?? elapsed;
    _lastElapsed = elapsed;
    var dt = (elapsed - last).inMicroseconds / 1e6 * timeScale;
    if (paused) dt = 0;
    _accum += dt;

    await _ensureResources(device, target.targetFormat);
    if (_renderPipeline == null) return;  // downlevel adapter — see above
    if (_pendingKernel != null || _device != device) {
      await _trySwapKernel(device);
    }
    if (_disposed) return;

    device.queue.writeBuffer(
      _uniforms!,
      Float32List.fromList(
              [dt, _accum, count.toDouble(), pointSize])
          .buffer
          .asUint8List(),
    );

    final encoder = device.createCommandEncoder(label: name);
    if (_computePipeline != null && dt > 0) {
      _computeBind ??=
          device.createBindGroup(layout: _computeBindLayout!, entries: [
        GpuBufferBinding(binding: 0, buffer: _uniforms!),
        GpuBufferBinding(binding: 1, buffer: _particles!),
      ]);
      final sim = encoder.beginComputePass(timestampWrites: timestamps);
      sim.setPipeline(_computePipeline!);
      sim.setBindGroup(0, _computeBind!);
      sim.dispatchWorkgroups((count + 63) ~/ 64);
      sim.end();
    } else if (_computePipeline == null &&
        _computeAvailable == false &&
        dt > 0) {
      _cpuSimulate(device, dt);
    }
    final pass = encoder.beginRenderPass(colorAttachments: [
      GpuColorAttachmentInfo(view: target.view, clearColor: GpuColor.black),
    ]);
    pass.setPipeline(_renderPipeline!);
    pass.setBindGroup(0, _renderBind!);
    pass.setVertexBuffer(0, _particles!);
    pass.draw(6, instanceCount: count);
    pass.end();
    device.queue.submit([encoder.finish()]);
  }

  /// Default swirl physics on the CPU for adapters without compute shaders
  /// — same motion as [defaultParticleKernel], uploaded each frame.
  void _cpuSimulate(GpuDevice device, double dt) {
    final p = _cpuParticles ??= Float32List.fromList(_seedParticles());
    for (var i = 0; i < count; i++) {
      final b = i * 4;
      final px = p[b], py = p[b + 1];
      var vx = p[b + 2], vy = p[b + 3];
      // toCenter + perpendicular swirl, matching the WGSL kernel.
      vx += (-px + py) * 0.15 * dt;
      vy += (-py - px) * 0.15 * dt;
      var nx = px + vx * dt;
      var ny = py + vy * dt;
      if (nx.abs() > 1.0) {
        vx = -vx;
        nx = nx.clamp(-1.0, 1.0);
      }
      if (ny.abs() > 1.0) {
        vy = -vy;
        ny = ny.clamp(-1.0, 1.0);
      }
      p[b] = nx;
      p[b + 1] = ny;
      p[b + 2] = vx;
      p[b + 3] = vy;
    }
    device.queue.writeBuffer(
        _particles!, p.buffer.asUint8List(p.offsetInBytes, p.lengthInBytes));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _computeBind?.dispose();
    _renderBind?.dispose();
    _renderLayout?.dispose();
    _computePipelineLayout?.dispose();
    _computeBindLayout?.dispose();
    _computePipeline?.dispose();
    _renderPipeline?.dispose();
    _computeModule?.dispose();
    _renderModule?.dispose();
    _uniforms?.dispose();
    _particles?.dispose();
    _device = null;
    compileError.dispose();
  }
}
