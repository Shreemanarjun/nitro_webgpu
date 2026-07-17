import 'package:flutter/foundation.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

import '../gpu/scenes.dart';

/// Slang-compiled COMPUTE shader (Shadertoy-style `imageMain`). This cannot
/// be used like the app's other shaders: they are RENDER shaders
/// (`vs_main`/`fs_main`) drawn straight into the view's render target, while
/// this one is a compute kernel that `textureStore`s into a
/// `texture_storage_2d<rgba8unorm, write>` — and a `WebGpuView` target is
/// not a storage texture (no STORAGE_BINDING usage; bgra8 on Apple).
/// [SlangComputeScene] below runs it the way it needs: dispatch into an
/// offscreen storage texture, then sample that texture to the screen.
///
/// Contract for shaders pasted into the compute toy (the Slang playground
/// convention):
///   `@group(0) @binding(0) var<uniform> { time: f32, frame: f32 }`
///   `@group(0) @binding(1) texture_storage_2d<rgba8unorm, write>`
///   `@compute` entry point named `imageMain`
final customShader = """
@binding(1) @group(0) var outputTexture_0 : texture_storage_2d<rgba8unorm, write>;

struct GlobalParams_std140_0
{
    @align(16) time_0 : f32,
    @align(4) frame_0 : f32,
};

@binding(0) @group(0) var<uniform> globalParams_0 : GlobalParams_std140_0;
struct imageMain_slang_Lambda_imageMain_1_0
{
     dispatchThreadID_0 : vec2<u32>,
};

fn imageMain_slang_Lambda_imageMain_1_x24init_0( dispatchThreadID_1 : vec2<u32>) -> imageMain_slang_Lambda_imageMain_1_0
{
    var _S1 : imageMain_slang_Lambda_imageMain_1_0;
    _S1.dispatchThreadID_0 = dispatchThreadID_1;
    return _S1;
}

fn float_getPi_0() -> f32
{
    return 3.14159274101257324f;
}

fn imageMain_slang_Lambda_imageMain_1_x28x29_0( this_0 : imageMain_slang_Lambda_imageMain_1_0,  screenSize_0 : vec2<i32>) -> vec4<f32>
{
    var _S2 : vec2<f32> = vec2<f32>(2.0f);
    var p_0 : vec2<f32> = (vec2<f32>(this_0.dispatchThreadID_0.xy) * _S2 - vec2<f32>(screenSize_0.xy)) / vec2<f32>(f32(screenSize_0.y));
    var tau_0 : f32 = float_getPi_0() * 2.0f;
    var _S3 : f32 = atan2(p_0.x, p_0.y) / tau_0;
    var uv_0 : vec2<f32> = vec2<f32>(_S3, length(p_0) * 0.75f);
    var t_0 : f32 = globalParams_0.frame_0 / 60.0f;
    var xCol_0 : f32 = ((((abs((_S3 - t_0 / 3.0f) * 3.0f))) % ((3.0f))));
    var horColour_0 : vec3<f32> = vec3<f32>(0.25f, 0.25f, 0.25f);
    if(xCol_0 < 1.0f)
    {
        horColour_0[i32(0)] = horColour_0[i32(0)] + (1.0f - xCol_0);
        horColour_0[i32(1)] = horColour_0[i32(1)] + xCol_0;
    }
    else
    {
        if(xCol_0 < 2.0f)
        {
            var xCol_1 : f32 = xCol_0 - 1.0f;
            horColour_0[i32(1)] = horColour_0[i32(1)] + (1.0f - xCol_1);
            horColour_0[i32(2)] = horColour_0[i32(2)] + xCol_1;
        }
        else
        {
            var xCol_2 : f32 = xCol_0 - 2.0f;
            horColour_0[i32(2)] = horColour_0[i32(2)] + (1.0f - xCol_2);
            horColour_0[i32(0)] = horColour_0[i32(0)] + xCol_2;
        }
    }
    var uv_1 : vec2<f32> = _S2 * uv_0 - vec2<f32>(1.0f);
    return vec4<f32>(vec3<f32>(((0.69999998807907104f + 0.5f * cos(uv_1.x * 10.0f * tau_0 * 0.15000000596046448f * clamp(floor(5.0f + 10.0f * cos(t_0)), 0.0f, 10.0f))) * abs(1.0f / (30.0f * uv_1.y)))) * horColour_0, 1.0f);
}

fn imageMain_slang_Lambda_imageMain_1_x24_syn_x28x29_0( this_1 : imageMain_slang_Lambda_imageMain_1_0,  _S4 : vec2<i32>) -> vec4<f32>
{
    return imageMain_slang_Lambda_imageMain_1_x28x29_0(this_1, _S4);
}

fn drawPixel_0( location_0 : vec2<u32>,  renderFunction_0 : imageMain_slang_Lambda_imageMain_1_0)
{
    var width_0 : u32 = u32(0);
    var height_0 : u32 = u32(0);
    {var dim = textureDimensions((outputTexture_0));((width_0)) = dim.x;((height_0)) = dim.y;};
    var color_0 : vec4<f32> = imageMain_slang_Lambda_imageMain_1_x24_syn_x28x29_0(renderFunction_0, vec2<i32>(i32(width_0), i32(height_0)));
    var _S5 : bool;
    if((location_0.x) >= width_0)
    {
        _S5 = true;
    }
    else
    {
        _S5 = (location_0.y) >= height_0;
    }
    if(_S5)
    {
        return;
    }
    textureStore((outputTexture_0), (location_0), (color_0));
    return;
}

@compute
@workgroup_size(16, 16, 1)
fn imageMain(@builtin(global_invocation_id) dispatchThreadID_2 : vec3<u32>)
{
    var dispatchThreadID_3 : vec2<u32> = dispatchThreadID_2.xy;
    drawPixel_0(dispatchThreadID_3, imageMain_slang_Lambda_imageMain_1_x24init_0(dispatchThreadID_3));
    return;
}
""";

/// Fullscreen pass that samples the compute output into the view target.
const _blitWgsl = '''
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main(@builtin(position) p: vec4f) -> @location(0) vec4f {
  let size = vec2f(textureDimensions(tex));
  return textureSample(tex, samp, p.xy / size);
}
''';

/// Hot-swappable compute-image scene: runs an `imageMain` compute kernel
/// over an offscreen rgba8unorm STORAGE texture sized to the view, then a
/// fixed fullscreen pass samples it into `target.view`.
///
/// [setSource] queues a new kernel; it compiles through the checked create
/// on the next frame. On validation errors the previous kernel keeps
/// rendering and naga's diagnostics are published on [compileError] — same
/// contract as the WGSL shader toy.
class SlangComputeScene implements GpuScene {
  SlangComputeScene({required String source}) : _pendingSource = source;

  @override
  String get name => 'compute-toy';

  /// Multiplies wall time fed to the kernel's `time`/`frame` uniforms.
  double timeScale = 1.0;

  bool paused = false;

  final ValueNotifier<String?> compileError = ValueNotifier(null);

  String? _pendingSource;
  String? _activeSource;
  double _accum = 0;
  Duration? _lastElapsed;
  bool _disposed = false;

  GpuDevice? _device;
  GpuShaderModule? _module;
  GpuComputePipeline? _pipeline;
  GpuBindGroupLayout? _computeLayout;
  GpuBindGroup? _computeBind;
  GpuBuffer? _uniforms;

  // Fixed blit infrastructure (not user-editable).
  GpuShaderModule? _blitModule;
  GpuRenderPipeline? _blitPipeline;
  GpuTextureFormat? _blitFormat;
  GpuBindGroupLayout? _blitLayout;
  GpuBindGroup? _blitBind;
  GpuSampler? _sampler;

  GpuTexture? _image;
  GpuTextureView? _imageView;
  int _width = 0;
  int _height = 0;

  /// Queues [source] for compilation on the next frame.
  void setSource(String source) => _pendingSource = source;

  Future<void> _trySwap(GpuDevice device) async {
    final source = _pendingSource ?? _activeSource;
    _pendingSource = null;
    if (source == null) return;
    GpuShaderModule? module;
    GpuComputePipeline? pipeline;
    GpuBindGroupLayout? layout;
    try {
      module = await device.createShaderModule(source, label: name);
      pipeline = await device.createComputePipeline(
          module: module, entryPoint: 'imageMain', label: name);
      layout = pipeline.getBindGroupLayout(0);
    } catch (e) {
      layout?.dispose();
      pipeline?.dispose();
      module?.dispose();
      if (!_disposed) {
        compileError.value = e is GpuValidationException ? e.message : '$e';
      }
      return;
    }
    if (_disposed) {
      layout.dispose();
      pipeline.dispose();
      module.dispose();
      return;
    }
    _computeBind?.dispose();
    _computeBind = null;
    _computeLayout?.dispose();
    _pipeline?.dispose();
    _module?.dispose();
    _module = module;
    _pipeline = pipeline;
    _computeLayout = layout;
    _activeSource = source;
    _device = device;
    compileError.value = null;
  }

  Future<void> _ensureBlit(
      GpuDevice device, GpuTextureFormat targetFormat) async {
    _sampler ??= device.createSampler(
        magFilter: GpuFilterMode.linear, minFilter: GpuFilterMode.linear);
    if (_blitPipeline != null && _blitFormat == targetFormat) return;
    _blitModule ??= await device.createShaderModule(_blitWgsl);
    _blitBind?.dispose();
    _blitBind = null;
    _blitLayout?.dispose();
    _blitPipeline?.dispose();
    _blitPipeline = await device.createRenderPipeline(
        module: _blitModule!, targetFormat: targetFormat);
    _blitFormat = targetFormat;
    _blitLayout = _blitPipeline!.getBindGroupLayout(0);
  }

  void _ensureImage(GpuDevice device, int width, int height) {
    if (_image != null && width == _width && height == _height) return;
    _width = width;
    _height = height;
    _computeBind?.dispose();
    _computeBind = null;
    _blitBind?.dispose();
    _blitBind = null;
    _imageView?.dispose();
    _image?.dispose();
    _image = device.createTexture(
      width: width,
      height: height,
      format: GpuTextureFormat.rgba8Unorm,
      usage: GpuTextureUsage.storageBinding | GpuTextureUsage.textureBinding,
      label: '$name-image',
    );
    _imageView = _image!.createView();
  }

  @override
  Future<void> render(GpuDevice device, GpuRenderTarget target,
      Duration elapsed, {GpuTimestampWrites? timestamps}) async {
    if (_disposed) return;
    final last = _lastElapsed ?? elapsed;
    _lastElapsed = elapsed;
    if (!paused) {
      _accum += (elapsed - last).inMicroseconds / 1e6 * timeScale;
    }

    _uniforms ??= device.createBuffer(
      size: 16,
      usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst,
      label: '$name-uniforms',
    );
    if (_pendingSource != null || _device != device) {
      await _trySwap(device);
    }
    await _ensureBlit(device, target.targetFormat);
    _ensureImage(device, target.width, target.height);
    if (_disposed) return;

    final pipeline = _pipeline;
    if (pipeline == null) {
      // Nothing compiled yet: still clear the target — presenting an
      // unrendered ring slot would flash content from several frames ago.
      final encoder = device.createCommandEncoder(label: '$name-clear');
      encoder
          .beginRenderPass(colorAttachments: [
            GpuColorAttachmentInfo(
                view: target.view, clearColor: GpuColor.black),
          ])
          .end();
      device.queue.submit([encoder.finish()]);
      return;
    }

    _computeBind ??= device.createBindGroup(layout: _computeLayout!, entries: [
      GpuBufferBinding(binding: 0, buffer: _uniforms!),
      GpuTextureBinding(binding: 1, view: _imageView!),
    ]);
    _blitBind ??= device.createBindGroup(layout: _blitLayout!, entries: [
      GpuSamplerBinding(binding: 0, sampler: _sampler!),
      GpuTextureBinding(binding: 1, view: _imageView!),
    ]);

    // GlobalParams_std140: { time: f32 @offset 0, frame: f32 @offset 4 }.
    // The Slang playground drives animation with `frame` at 60 fps.
    device.queue.writeBuffer(
      _uniforms!,
      Float32List.fromList([_accum, _accum * 60.0, 0, 0]).buffer.asUint8List(),
    );

    final encoder = device.createCommandEncoder(label: name);
    final compute = encoder.beginComputePass(timestampWrites: timestamps);
    compute.setPipeline(pipeline);
    compute.setBindGroup(0, _computeBind!);
    compute.dispatchWorkgroups(
        (target.width + 15) ~/ 16, (target.height + 15) ~/ 16);
    compute.end();

    final pass = encoder.beginRenderPass(colorAttachments: [
      GpuColorAttachmentInfo(view: target.view, clearColor: GpuColor.black),
    ]);
    pass.setPipeline(_blitPipeline!);
    pass.setBindGroup(0, _blitBind!);
    pass.draw(3);
    pass.end();
    device.queue.submit([encoder.finish()]);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _computeBind?.dispose();
    _blitBind?.dispose();
    _computeLayout?.dispose();
    _blitLayout?.dispose();
    _imageView?.dispose();
    _image?.dispose();
    _sampler?.dispose();
    _uniforms?.dispose();
    _blitPipeline?.dispose();
    _blitModule?.dispose();
    _pipeline?.dispose();
    _module?.dispose();
    compileError.dispose();
  }
}
