import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../api/gpu.dart';
import '../foundation/web_gpu_builder.dart';
import '../presentation/web_gpu_view.dart';

/// The language of a [WebGpuShaderView] fragment.
enum ShaderViewLanguage { wgsl, glsl }

/// A full-screen animated shader as a single widget — the fastest way to
/// put GPU pixels on screen:
///
/// ```dart
/// WebGpuShaderView(fragment: '''
/// @fragment
/// fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
///   let uv = pos.xy / nw.resolution;
///   return vec4f(uv, 0.5 + 0.5 * sin(nw.time), 1.0);
/// }
/// ''')
/// ```
///
/// The widget owns everything: the shared device ([WebGpu.device]), the
/// fullscreen-triangle vertex stage, per-frame uniforms, pipeline caching,
/// presentation ([WebGpuView]), and lifecycle. The fragment source can be
/// swapped live (hot reload included) — compile errors keep the last good
/// shader running and surface through [onError] / an overlay.
///
/// WGSL fragments see these built-ins (auto-prepended; entry point
/// `fs_main`):
///
/// ```wgsl
/// struct NwUniforms {
///   time: f32,            // seconds since the view appeared
///   resolution: vec2f,    // render size in physical pixels
///   mouse: vec2f,         // last touch/hover, in pixels
///   mouseDown: f32,       // 1.0 while pressed
/// };
/// @group(0) @binding(0) var<uniform> nw: NwUniforms;
/// ```
///
/// GLSL fragments ([language] == [ShaderViewLanguage.glsl], entry point
/// `main`, `#version 450` prepended) see the equivalent block plus
/// `layout(location = 0) out vec4 fragColor`.
class WebGpuShaderView extends StatefulWidget {
  const WebGpuShaderView({
    super.key,
    this.fragment,
    this.language = ShaderViewLanguage.wgsl,
    this.renderScale = 1.0,
    this.filterQuality = FilterQuality.low,
    this.onError,
  });

  /// Fragment-stage source (see the class docs for the contract). When
  /// null, a built-in demo gradient renders — useful as a placeholder.
  final String? fragment;

  final ShaderViewLanguage language;

  /// See [WebGpuView.renderScale].
  final double renderScale;

  final FilterQuality filterQuality;

  /// Called with the compiler diagnostics when [fragment] fails to
  /// compile. Without a handler, an overlay shows the message.
  final void Function(String message)? onError;

  @override
  State<WebGpuShaderView> createState() => _WebGpuShaderViewState();
}

// Layout (32 bytes): time@0, (pad)@4, resolution@8, mouse@16, mouseDown@24,
// size rounds up to the struct's 8-byte alignment. Must stay in sync with
// the uniform buffer size and the per-frame Float32List in _frame.
const _wgslPrelude = '''
struct NwUniforms {
  time: f32,
  resolution: vec2f,
  mouse: vec2f,
  mouseDown: f32,
};
@group(0) @binding(0) var<uniform> nw: NwUniforms;

@vertex
fn nw_vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var p = array<vec2f, 3>(vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(p[i], 0.0, 1.0);
}
''';

const _glslPrelude = '''#version 450
layout(set = 0, binding = 0) uniform NwUniforms {
  float time;
  vec2 resolution;
  vec2 mouse;
  float mouseDown;
} nw;
layout(location = 0) out vec4 fragColor;
''';

const _defaultFragment = '''
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let uv = pos.xy / nw.resolution;
  let wave = sin(uv.x * 6.0 + nw.time) * cos(uv.y * 4.0 - nw.time * 0.7);
  return vec4f(0.1 + 0.5 * wave, 0.2 + uv.y * 0.5, 0.6 - 0.3 * wave, 1.0);
}
''';

class _WebGpuShaderViewState extends State<WebGpuShaderView> {
  GpuBuffer? _uniforms;
  GpuShaderModule? _vertexModule;

  // Last-good pipeline state; a failed swap keeps rendering with these.
  GpuShaderModule? _fragmentModule;
  GpuRenderPipeline? _pipeline;
  GpuBindGroup? _bind;
  GpuTextureFormat? _pipelineFormat;
  String? _builtSource;
  bool _validated = false;

  String? _error;
  double _mouseX = 0, _mouseY = 0, _mouseDown = 0;
  bool _swapping = false;

  String get _source => widget.fragment ?? _defaultFragment;

  Future<void> _ensurePipeline(
      GpuDevice device, GpuTextureFormat format) async {
    if (_swapping) return;
    _swapping = true;
    try {
      _uniforms ??= device.createBuffer(
          size: 32,
          usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst,
          label: 'shader-view-uniforms');
      _vertexModule ??= await device.createShaderModule(_wgslPrelude,
          label: 'shader-view-vs');

      final source = _source;
      GpuShaderModule? fragment;
      GpuRenderPipeline pipeline;
      try {
        final String entry;
        if (widget.language == ShaderViewLanguage.glsl) {
          fragment = await device.createShaderModuleGlsl(
              _glslPrelude + source,
              stage: GpuShaderStage.fragment,
              label: 'shader-view-fs');
          entry = 'main';
        } else {
          fragment = await device.createShaderModule(_wgslPrelude + source,
              label: 'shader-view-fs');
          entry = 'fs_main';
        }
        pipeline = await device.createRenderPipeline(
          module: _vertexModule!,
          vertexEntryPoint: 'nw_vs',
          fragmentModule: fragment,
          fragmentEntryPoint: entry,
          targetFormat: format,
          label: 'shader-view-pipeline',
        );
      } catch (e) {
        fragment?.dispose();
        // Remember the broken source so it isn't recompiled every frame;
        // the last good pipeline (or nothing, first time) keeps showing.
        _builtSource = source;
        _reportError(e is GpuValidationException ? e.message : '$e');
        return;
      }

      // The fragment may declare bindings this widget doesn't provide (or
      // none at all, if it never reads `nw`) — create the uniform bind
      // group under an error scope so a mismatch degrades instead of
      // poisoning the frame.
      device.pushErrorScope(GpuErrorFilter.validation);
      final bind = device.createBindGroup(
          layout: pipeline.getBindGroupLayout(0),
          entries: [GpuBufferBinding(binding: 0, buffer: _uniforms!)]);
      final bindError = await device.popErrorScope();

      _bind?.dispose();
      _pipeline?.dispose();
      _fragmentModule?.dispose();
      _fragmentModule = fragment;
      _pipeline = pipeline;
      _pipelineFormat = format;
      _builtSource = source;
      _validated = false;
      if (bindError == null) {
        _bind = bind;
      } else {
        // Draw without group 0; the first-frame validation in _frame
        // decides whether the pipeline actually needed it.
        bind.dispose();
        _bind = null;
      }
      if (mounted && _error != null) setState(() => _error = null);
    } finally {
      _swapping = false;
    }
  }

  void _reportError(String message) {
    if (!mounted) return;
    widget.onError?.call(message);
    setState(() => _error = message);
  }

  Future<void> _frame(
      GpuDevice device, GpuRenderTarget target, Duration elapsed) async {
    if (_builtSource != _source || _pipelineFormat != target.targetFormat) {
      await _ensurePipeline(device, target.targetFormat);
    }
    final pipeline = _pipeline;
    final bind = _bind;
    if (pipeline == null) return;

    device.queue.writeBuffer(
        _uniforms!,
        Float32List.fromList([
          elapsed.inMicroseconds / 1e6,
          0, // vec2 alignment: resolution starts at byte 8
          target.width.toDouble(),
          target.height.toDouble(),
          _mouseX,
          _mouseY,
          _mouseDown,
          0, // struct size rounds up to its 8-byte alignment
        ]).buffer.asUint8List());

    // Submitting invalid work is fatal in the native layer, so the first
    // frame of every fresh pipeline is proven under an error scope before
    // anything reaches the queue.
    final validate = !_validated;
    if (validate) device.pushErrorScope(GpuErrorFilter.validation);
    final encoder = device.createCommandEncoder(label: 'shader-view');
    final pass = encoder.beginRenderPass(colorAttachments: [
      GpuColorAttachmentInfo(view: target.view),
    ])
      ..setPipeline(pipeline);
    if (bind != null) pass.setBindGroup(0, bind);
    pass
      ..draw(3)
      ..end();
    final commands = encoder.finish();
    if (validate) {
      final error = await device.popErrorScope();
      if (error != null) {
        commands.dispose();
        _bind?.dispose();
        _pipeline?.dispose();
        _fragmentModule?.dispose();
        _bind = null;
        _pipeline = null;
        _fragmentModule = null;
        _reportError(error.message);
        return;
      }
      _validated = true;
    }
    device.queue.submit([commands]);
  }

  @override
  void dispose() {
    _bind?.dispose();
    _pipeline?.dispose();
    _fragmentModule?.dispose();
    _vertexModule?.dispose();
    _uniforms?.dispose();
    // The shared device is app-lifetime; never disposed here.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return WebGpuBuilder(
      builder: (context, device) {
        Widget view = Listener(
          onPointerDown: (e) {
            _mouseDown = 1;
            _mouseX = e.localPosition.dx * dpr * widget.renderScale;
            _mouseY = e.localPosition.dy * dpr * widget.renderScale;
          },
          onPointerMove: (e) {
            _mouseX = e.localPosition.dx * dpr * widget.renderScale;
            _mouseY = e.localPosition.dy * dpr * widget.renderScale;
          },
          onPointerUp: (_) => _mouseDown = 0,
          child: WebGpuView(
            device: device,
            renderScale: widget.renderScale,
            filterQuality: widget.filterQuality,
            onFrame: (target, elapsed) => _frame(device, target, elapsed),
          ),
        );
        final error = _error;
        if (error != null && widget.onError == null) {
          view = Stack(fit: StackFit.expand, children: [
            view,
            IgnorePointer(
              child: Container(
                alignment: Alignment.bottomLeft,
                padding: const EdgeInsets.all(12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xCC300000),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      error,
                      style: const TextStyle(
                          color: Color(0xFFFFB4B4), fontSize: 11),
                    ),
                  ),
                ),
              ),
            ),
          ]);
        }
        return view;
      },
    );
  }
}
