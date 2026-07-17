import 'package:flutter/foundation.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

import 'scenes.dart';

/// Language of a Shadertoy-style pass.
enum ShadertoyLanguage {
  /// A WGSL snippet: `fn mainImage(fragCoord: vec2f) -> vec4f { ... }`.
  /// The engine wraps it with the vertex shader, the Shadertoy uniforms
  /// (`iTime`, `iTimeDelta`, `iFrame`, `iResolution`, `iMouse`) and the
  /// channel bindings (`iChannel0..3` + `stSampler`).
  wgslSnippet,

  /// A GLSL snippet pasted straight from shadertoy.com:
  /// `void mainImage(out vec4 fragColor, in vec2 fragCoord) { ... }`.
  /// Same uniforms/channels, exposed with Shadertoy's exact names.
  glsl,
}

/// What an `iChannelN` samples.
enum ShadertoyChannelKind { none, bufferA, bufferB, bufferC, bufferD, texture }

class ShadertoyChannel {
  const ShadertoyChannel.none()
      : kind = ShadertoyChannelKind.none,
        texture = null;
  const ShadertoyChannel.buffer(this.kind) : texture = null;
  const ShadertoyChannel.image(GpuTexture this.texture)
      : kind = ShadertoyChannelKind.texture;

  final ShadertoyChannelKind kind;

  /// Borrowed — the caller owns provided textures.
  final GpuTexture? texture;
}

/// One pass: the Image pass or one of Buffer A–D.
class ShadertoyPassSpec {
  const ShadertoyPassSpec({
    required this.language,
    required this.source,
    this.channels = const [
      ShadertoyChannel.none(),
      ShadertoyChannel.none(),
      ShadertoyChannel.none(),
      ShadertoyChannel.none(),
    ],
  });

  final ShadertoyLanguage language;
  final String source;

  /// Exactly four entries — `iChannel0..3`.
  final List<ShadertoyChannel> channels;
}

/// Shadertoy-compatible multi-pass engine.
///
/// Frame flow: Buffer A→D render (each into its own double-buffered
/// offscreen rgba16float texture), then the Image pass renders into the
/// view target; afterwards every buffer's front/back swap. All `iChannelN`
/// buffer reads sample the PREVIOUS frame's output — that makes
/// self-feedback (trails, simulations) exact, and cross-buffer reads lag
/// one frame.
///
/// Pass sources hot-swap through the checked creates: on a naga error the
/// previous pipeline keeps rendering and the diagnostics are published on
/// [compileError] — the same contract as the WGSL shader toy.
class ShadertoyEngine implements GpuScene {
  ShadertoyEngine({required ShadertoyPassSpec image, this.buffers})
      : assert(buffers == null || buffers.length <= 4) {
    _pending[4] = image;
    for (var i = 0; i < (buffers?.length ?? 0); i++) {
      final b = buffers![i];
      if (b != null) _pending[i] = b;
    }
  }

  final List<ShadertoyPassSpec?>? buffers;

  @override
  String get name => 'shadertoy';

  double timeScale = 1.0;
  bool paused = false;

  /// Shadertoy `iMouse`: xy = latest drag position (pixels), zw = position
  /// of the last press. Update from a GestureDetector.
  double mouseX = 0, mouseY = 0, mouseClickX = 0, mouseClickY = 0;

  double? _mouseNX, _mouseNY, _mouseClickNX, _mouseClickNY;

  /// UI-friendly mouse input: [nx]/[ny] are normalized 0..1 in the view's
  /// box (y down, Flutter convention). Converted to Shadertoy's
  /// bottom-left-origin pixel space at render time, so it tracks dynamic
  /// resolution automatically.
  void setMouseNormalized(double nx, double ny, {bool press = false}) {
    _mouseNX = nx;
    _mouseNY = ny;
    if (press) {
      _mouseClickNX = nx;
      _mouseClickNY = ny;
    }
  }

  final ValueNotifier<String?> compileError = ValueNotifier(null);

  // Slot 0-3 = Buffer A-D, slot 4 = Image.
  final Map<int, ShadertoyPassSpec> _pending = {};
  final Map<int, _Pass> _passes = {};
  bool _disposed = false;

  GpuShaderModule? _vsModule; // shared WGSL fullscreen-triangle vertex
  GpuSampler? _sampler;
  GpuBuffer? _uniforms;
  GpuTexture? _blackTexture; // bound to unused channels
  GpuTextureView? _blackView;
  GpuTextureFormat? _imageFormat;

  double _accum = 0;
  double _delta = 0;
  int _frame = 0;
  Duration? _lastElapsed;
  int _width = 0, _height = 0;

  /// Replaces one pass (0–3 = Buffer A–D, 4 = Image); compiles next frame.
  void setPass(int slot, ShadertoyPassSpec spec) => _pending[slot] = spec;

  static const _wgslPrelude = '''
struct STUniforms {
  res: vec4f,
  time: vec4f,
  mouse: vec4f,
};
@group(0) @binding(0) var<uniform> st_u: STUniforms;
@group(0) @binding(1) var stSampler: sampler;
@group(0) @binding(2) var iChannel0: texture_2d<f32>;
@group(0) @binding(3) var iChannel1: texture_2d<f32>;
@group(0) @binding(4) var iChannel2: texture_2d<f32>;
@group(0) @binding(5) var iChannel3: texture_2d<f32>;

var<private> iResolution: vec3f;
var<private> iTime: f32;
var<private> iTimeDelta: f32;
var<private> iFrame: f32;
var<private> iMouse: vec4f;
''';

  static const _wgslEpilogue = '''

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var p = array<vec2f, 3>(vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(p[i], 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) st_pos: vec4f) -> @location(0) vec4f {
  iResolution = st_u.res.xyz;
  iTime = st_u.time.x;
  iTimeDelta = st_u.time.y;
  iFrame = st_u.time.z;
  iMouse = st_u.mouse;
  // Keep every binding statically used so the auto layout stays stable no
  // matter which channels the snippet touches.
  var st_keep = textureSampleLevel(iChannel0, stSampler, vec2f(0.5), 0.0);
  st_keep += textureSampleLevel(iChannel1, stSampler, vec2f(0.5), 0.0);
  st_keep += textureSampleLevel(iChannel2, stSampler, vec2f(0.5), 0.0);
  st_keep += textureSampleLevel(iChannel3, stSampler, vec2f(0.5), 0.0);
  let fragCoord = vec2f(st_pos.x, iResolution.y - st_pos.y);
  return mainImage(fragCoord) + st_keep * 0.0;
}
''';

  static const _glslPrelude = '''
#version 450
layout(location = 0) out vec4 st_outColor;
layout(set = 0, binding = 0) uniform STUniforms {
  vec4 st_res;
  vec4 st_time;
  vec4 st_mouse;
};
layout(set = 0, binding = 1) uniform sampler stSampler;
layout(set = 0, binding = 2) uniform texture2D iChannel0T;
layout(set = 0, binding = 3) uniform texture2D iChannel1T;
layout(set = 0, binding = 4) uniform texture2D iChannel2T;
layout(set = 0, binding = 5) uniform texture2D iChannel3T;
#define iChannel0 sampler2D(iChannel0T, stSampler)
#define iChannel1 sampler2D(iChannel1T, stSampler)
#define iChannel2 sampler2D(iChannel2T, stSampler)
#define iChannel3 sampler2D(iChannel3T, stSampler)
#define iResolution (st_res.xyz)
#define iTime (st_time.x)
#define iTimeDelta (st_time.y)
#define iFrame (st_time.z)
#define iMouse (st_mouse)
''';

  static const _glslEpilogue = '''

void main() {
  vec2 fragCoord = vec2(gl_FragCoord.x, iResolution.y - gl_FragCoord.y);
  vec4 st_color = vec4(0.0);
  mainImage(st_color, fragCoord);
  vec4 st_keep = texture(iChannel0, vec2(0.5)) + texture(iChannel1, vec2(0.5))
               + texture(iChannel2, vec2(0.5)) + texture(iChannel3, vec2(0.5));
  st_outColor = st_color + st_keep * 0.0;
}
''';

  /// Wraps a WGSL `mainImage` snippet into a complete module.
  static String wrapWgsl(String snippet) =>
      '$_wgslPrelude\n$snippet\n$_wgslEpilogue';

  /// Wraps a shadertoy.com GLSL `mainImage` into a complete GLSL fragment.
  static String wrapGlsl(String snippet) =>
      '$_glslPrelude\n$snippet\n$_glslEpilogue';

  Future<void> _ensureShared(GpuDevice device) async {
    _vsModule ??= await device.createShaderModule('''
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var p = array<vec2f, 3>(vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(p[i], 0.0, 1.0);
}
''', label: '$name-vs');
    _sampler ??= device.createSampler(
        magFilter: GpuFilterMode.linear, minFilter: GpuFilterMode.linear);
    _uniforms ??= device.createBuffer(
        size: 48,
        usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst,
        label: '$name-uniforms');
    if (_blackTexture == null) {
      _blackTexture = device.createTexture(
        width: 1,
        height: 1,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
        label: '$name-black',
      );
      device.queue.writeTexture(_blackTexture!, Uint8List(4));
      _blackView = _blackTexture!.createView();
    }
  }

  Future<void> _trySwap(int slot, ShadertoyPassSpec spec, GpuDevice device,
      GpuTextureFormat format) async {
    GpuShaderModule? module;
    GpuRenderPipeline? pipeline;
    GpuBindGroupLayout? layout;
    try {
      switch (spec.language) {
        case ShadertoyLanguage.wgslSnippet:
          module = await device.createShaderModule(wrapWgsl(spec.source),
              label: '$name-$slot');
          pipeline = await device.createRenderPipeline(
              module: module, targetFormat: format, label: '$name-$slot');
        case ShadertoyLanguage.glsl:
          module = await device.createShaderModuleGlsl(wrapGlsl(spec.source),
              stage: GpuShaderStage.fragment, label: '$name-$slot');
          pipeline = await device.createRenderPipeline(
              module: _vsModule!,
              fragmentModule: module,
              fragmentEntryPoint: 'main',
              targetFormat: format,
              label: '$name-$slot');
      }
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
    final old = _passes[slot];
    old?.disposePipeline();
    final pass = old ?? _Pass(slot);
    pass
      ..spec = spec
      ..module = module
      ..pipeline = pipeline
      ..layout = layout
      ..format = format;
    _passes[slot] = pass;
    compileError.value = null;
  }

  void _ensureBufferTargets(GpuDevice device, int width, int height) {
    for (final pass in _passes.values) {
      if (pass.slot == 4) continue;
      pass.ensureTargets(device, width, height);
    }
  }

  GpuTextureView _channelView(ShadertoyChannel channel) {
    switch (channel.kind) {
      case ShadertoyChannelKind.none:
        return _blackView!;
      case ShadertoyChannelKind.texture:
        return _viewFor(channel.texture!);
      case ShadertoyChannelKind.bufferA:
      case ShadertoyChannelKind.bufferB:
      case ShadertoyChannelKind.bufferC:
      case ShadertoyChannelKind.bufferD:
        final slot = channel.kind.index - ShadertoyChannelKind.bufferA.index;
        final pass = _passes[slot];
        // Front = the previous frame's completed output.
        return pass?.frontView ?? _blackView!;
    }
  }

  // Views for caller-provided channel textures, cached per texture.
  final Map<GpuTexture, GpuTextureView> _textureViews = {};
  GpuTextureView _viewFor(GpuTexture texture) =>
      _textureViews[texture] ??= texture.createView();

  @override
  Future<void> render(GpuDevice device, GpuRenderTarget target,
      Duration elapsed, {GpuTimestampWrites? timestamps}) async {
    if (_disposed) return;
    final last = _lastElapsed ?? elapsed;
    _lastElapsed = elapsed;
    _delta = (elapsed - last).inMicroseconds / 1e6 * timeScale;
    if (!paused) {
      _accum += _delta;
      _frame++;
    }

    await _ensureShared(device);
    if (_disposed) return;

    // Compile pending passes (image pass targets the view's format, buffer
    // passes render to rgba16float offscreen targets).
    if (_pending.isNotEmpty ||
        (_imageFormat != null && _imageFormat != target.targetFormat)) {
      if (_imageFormat != null && _imageFormat != target.targetFormat) {
        final image = _passes[4];
        if (image != null) _pending[4] = image.spec!;
      }
      final work = Map<int, ShadertoyPassSpec>.from(_pending);
      _pending.clear();
      for (final entry in work.entries) {
        final format = entry.key == 4
            ? target.targetFormat
            : GpuTextureFormat.rgba16Float;
        await _trySwap(entry.key, entry.value, device, format);
      }
      _imageFormat = target.targetFormat;
    }
    if (_disposed) return;

    _width = target.width;
    _height = target.height;
    _ensureBufferTargets(device, _width, _height);

    if (_mouseNX != null) {
      mouseX = _mouseNX! * _width;
      mouseY = (1 - _mouseNY!) * _height; // Shadertoy origin: bottom-left.
      mouseClickX = (_mouseClickNX ?? 0) * _width;
      mouseClickY = (1 - (_mouseClickNY ?? 1)) * _height.toDouble();
    }

    device.queue.writeBuffer(
      _uniforms!,
      Float32List.fromList([
        _width.toDouble(), _height.toDouble(), 1, 0, // iResolution
        _accum, _delta, _frame.toDouble(), 0, // iTime/iTimeDelta/iFrame
        mouseX, mouseY, mouseClickX, mouseClickY, // iMouse
      ]).buffer.asUint8List(),
    );

    final image = _passes[4];
    if (image?.pipeline == null) {
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

    final encoder = device.createCommandEncoder(label: name);
    final trash = <GpuBindGroup>[];

    void encodePass(_Pass pass, GpuTextureView into,
        {GpuTimestampWrites? stamps}) {
      final bind = device.createBindGroup(layout: pass.layout!, entries: [
        GpuBufferBinding(binding: 0, buffer: _uniforms!),
        GpuSamplerBinding(binding: 1, sampler: _sampler!),
        for (var c = 0; c < 4; c++)
          GpuTextureBinding(
              binding: 2 + c, view: _channelView(pass.spec!.channels[c])),
      ]);
      trash.add(bind);
      final rp = encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(view: into, clearColor: GpuColor.black),
      ], timestampWrites: stamps);
      rp.setPipeline(pass.pipeline!);
      rp.setBindGroup(0, bind);
      rp.draw(3);
      rp.end();
    }

    for (var slot = 0; slot < 4; slot++) {
      final pass = _passes[slot];
      if (pass?.pipeline == null) continue;
      encodePass(pass!, pass.backView!);
    }
    encodePass(image!, target.view, stamps: timestamps);

    device.queue.submit([encoder.finish()]);
    for (final bind in trash) {
      bind.dispose();
    }
    for (var slot = 0; slot < 4; slot++) {
      _passes[slot]?.swap();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final pass in _passes.values) {
      pass.disposeAll();
    }
    _passes.clear();
    for (final view in _textureViews.values) {
      view.dispose();
    }
    _textureViews.clear();
    _blackView?.dispose();
    _blackTexture?.dispose();
    _uniforms?.dispose();
    _sampler?.dispose();
    _vsModule?.dispose();
    compileError.dispose();
  }
}

class _Pass {
  _Pass(this.slot);

  final int slot; // 0-3 = Buffer A-D, 4 = Image
  ShadertoyPassSpec? spec;
  GpuShaderModule? module;
  GpuRenderPipeline? pipeline;
  GpuBindGroupLayout? layout;
  GpuTextureFormat? format;

  // Double-buffered offscreen targets (buffer passes only).
  GpuTexture? _texA, _texB;
  GpuTextureView? _viewA, _viewB;
  bool _frontIsA = true;
  int _w = 0, _h = 0;

  GpuTextureView? get frontView => _frontIsA ? _viewA : _viewB;
  GpuTextureView? get backView => _frontIsA ? _viewB : _viewA;
  void swap() => _frontIsA = !_frontIsA;

  void ensureTargets(GpuDevice device, int width, int height) {
    if (_texA != null && _w == width && _h == height) return;
    _w = width;
    _h = height;
    _disposeTargets();
    GpuTexture make() => device.createTexture(
          width: width,
          height: height,
          format: GpuTextureFormat.rgba16Float,
          usage:
              GpuTextureUsage.renderAttachment | GpuTextureUsage.textureBinding,
          label: 'shadertoy-buffer-$slot',
        );
    _texA = make();
    _texB = make();
    _viewA = _texA!.createView();
    _viewB = _texB!.createView();
    _frontIsA = true;
  }

  void disposePipeline() {
    layout?.dispose();
    pipeline?.dispose();
    module?.dispose();
    layout = null;
    pipeline = null;
    module = null;
  }

  void _disposeTargets() {
    _viewA?.dispose();
    _viewB?.dispose();
    _texA?.dispose();
    _texB?.dispose();
    _viewA = null;
    _viewB = null;
    _texA = null;
    _texB = null;
  }

  void disposeAll() {
    disposePipeline();
    _disposeTargets();
  }
}
