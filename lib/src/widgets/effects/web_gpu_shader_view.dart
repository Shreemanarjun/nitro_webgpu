import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../api/gpu.dart';
import '../foundation/web_gpu_builder.dart';
import '../presentation/web_gpu_view.dart';

/// The language of a [WebGpuShaderView] fragment.
enum ShaderViewLanguage { wgsl, glsl }

/// Imperative control over a [WebGpuShaderView]:
///
/// ```dart
/// final controller = WebGpuShaderViewController();
/// WebGpuShaderView(fragment: src, controller: controller);
/// // later:
/// controller.pause();          // zero GPU work while off-screen/static
/// controller.requestFrame();   // one frame, nw.time frozen
/// controller.resume();
/// controller.resetTime();      // nw.time restarts at 0
/// print(controller.lastError); // latest compile diagnostics, or null
/// ```
///
/// Live stats mirror the underlying [WebGpuViewController]: [frameCount],
/// [fps], [time], [hasPresented], [renderSize]. For touch UIs,
/// [setKeyLane] drives the `nw.keys` lanes from on-screen buttons —
/// injected lanes merge with physical keys instead of fighting them.
class WebGpuShaderViewController {
  /// The underlying presentation controller — usable directly for
  /// anything [WebGpuView] supports.
  final WebGpuViewController view = WebGpuViewController();

  _WebGpuShaderViewState? _state;
  bool _resetTime = false;
  final Float32List _injectedLanes = Float32List(4);

  bool get isPaused => view.isPaused;

  /// Frames rendered so far.
  int get frameCount => view.frameCount;

  /// Smoothed frames-per-second (0 until measured).
  double get fps => view.fps;

  /// Whether at least one frame is on screen.
  bool get hasPresented => view.hasPresented;

  /// Current render-target size in physical pixels.
  Size get renderSize => view.renderSize;

  /// The current `nw.time` in seconds — the value the latest frame saw.
  double get time => _state?._lastTime ?? 0;

  /// Stops the frame loop (`nw.time` freezes with it).
  void pause() => view.pause();

  /// Restarts the frame loop; `nw.time` continues from where it froze.
  void resume() => view.resume();

  /// Renders exactly one frame while paused.
  void requestFrame() => view.requestFrame();

  /// Restarts `nw.time` at zero on the next rendered frame.
  void resetTime() => _resetTime = true;

  /// Holds or releases one of the four `nw.keys` lanes programmatically —
  /// the touch-screen counterpart to the keyboard: wire on-screen D-pad
  /// buttons to `setKeyLane(0, true)` on press and `(0, false)` on
  /// release. Injected lanes merge with (never fight) physical keys.
  void setKeyLane(int lane, bool down) {
    _injectedLanes[lane] = down ? 1.0 : 0.0;
    _state?._recomputeKeyLanes();
  }

  /// The latest compile/validation diagnostics, or null while healthy.
  String? get lastError => _state?._error;

  bool get hasError => lastError != null;
}

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
///   keys: vec4f,          // left/right/up/down — arrows or WASD, 1.0 held
/// };
/// @group(0) @binding(0) var<uniform> nw: NwUniforms;
/// ```
///
/// Keys are tracked globally (no focus dance — a shader reacts to arrows
/// the moment it's on screen), so games are one fragment away:
/// `pos += (nw.keys.y - nw.keys.x) * speed`. Remap the four lanes to any
/// keys with [keyBindings].
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
    this.errorBuilder,
    this.loadingBuilder,
    this.keyBindings,
    this.controller,
  });

  /// Fragment-stage source (see the class docs for the contract). When
  /// null, a built-in demo gradient renders — useful as a placeholder.
  final String? fragment;

  final ShaderViewLanguage language;

  /// See [WebGpuView.renderScale].
  final double renderScale;

  final FilterQuality filterQuality;

  /// Called with the compiler diagnostics when [fragment] fails to
  /// compile. Without a handler (and without [errorBuilder]), a built-in
  /// overlay shows the message.
  final void Function(String message)? onError;

  /// Builds a custom overlay for compile/validation errors (stacked over
  /// the last good frame) and for device-creation failures. Takes
  /// precedence over the built-in overlay; [onError] still fires.
  final Widget Function(BuildContext context, String message)? errorBuilder;

  /// Built while the shared device boots. Defaults to an empty box.
  final WidgetBuilder? loadingBuilder;

  /// Which keys drive the four `nw.keys` lanes (x, y, z, w) — up to four
  /// slots, each activated while any of its keys is held. Defaults to
  /// left/right/up/down as arrows or WASD:
  ///
  /// ```dart
  /// WebGpuShaderView(
  ///   keyBindings: [
  ///     {LogicalKeyboardKey.keyJ},                          // nw.keys.x
  ///     {LogicalKeyboardKey.keyL},                          // nw.keys.y
  ///     {LogicalKeyboardKey.keyI, LogicalKeyboardKey.space}, // nw.keys.z
  ///     {LogicalKeyboardKey.keyK},                          // nw.keys.w
  ///   ],
  ///   fragment: ...,
  /// )
  /// ```
  final List<Set<LogicalKeyboardKey>>? keyBindings;

  /// Optional imperative control (pause/resume/single-frame/resetTime).
  final WebGpuShaderViewController? controller;

  @override
  State<WebGpuShaderView> createState() => _WebGpuShaderViewState();
}

// Layout (48 bytes): time@0, (pad)@4, resolution@8, mouse@16, mouseDown@24,
// (pad)@28, keys@32 (vec4f aligns to 16). Must stay in sync with
// _uniformData in the state below — same layout in both preludes.
const _wgslPrelude = '''
struct NwUniforms {
  time: f32,
  resolution: vec2f,
  mouse: vec2f,
  mouseDown: f32,
  keys: vec4f,
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
  vec4 keys;
} nw;
layout(location = 0) out vec4 fragColor;
''';

final _defaultKeyBindings = <Set<LogicalKeyboardKey>>[
  {LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.keyA},
  {LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.keyD},
  {LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.keyW},
  {LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.keyS},
];

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

  // Reused every frame (no per-frame allocation): floats 0-7 are written
  // in _frame, 8-11 (keys: left/right/up/down) by the key handler.
  final Float32List _uniformData = Float32List(12);
  late final Uint8List _uniformBytes = _uniformData.buffer.asUint8List();

  String get _source => widget.fragment ?? _defaultFragment;

  Duration _timeBase = Duration.zero;
  double _lastTime = 0;

  // Global key tracking: reacts without a focus dance, never consumes.
  final Set<LogicalKeyboardKey> _held = {};

  void _recomputeKeyLanes() {
    final bindings = widget.keyBindings ?? _defaultKeyBindings;
    final injected = widget.controller?._injectedLanes;
    for (var i = 0; i < 4; i++) {
      var v = 0.0;
      if (i < bindings.length) {
        for (final key in bindings[i]) {
          if (_held.contains(key)) {
            v = 1.0;
            break;
          }
        }
      }
      if (injected != null && injected[i] > v) v = injected[i];
      _uniformData[8 + i] = v;
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _held.add(event.logicalKey);
    } else if (event is KeyUpEvent) {
      _held.remove(event.logicalKey);
    } else {
      return false;
    }
    _recomputeKeyLanes();
    return false;
  }

  @override
  void initState() {
    super.initState();
    assert(widget.controller?._state == null,
        'WebGpuShaderViewController is already attached to another view');
    widget.controller?._state = this;
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didUpdateWidget(WebGpuShaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._state == this) {
        oldWidget.controller?._state = null;
      }
      widget.controller?._state = this;
    }
    if (!identical(oldWidget.keyBindings, widget.keyBindings)) {
      _recomputeKeyLanes();
    }
  }

  Future<void> _ensurePipeline(
      GpuDevice device, GpuTextureFormat format) async {
    if (_swapping) return;
    _swapping = true;
    try {
      _uniforms ??= device.createBuffer(
          size: 48,
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

    final controller = widget.controller;
    if (controller != null && controller._resetTime) {
      controller._resetTime = false;
      _timeBase = elapsed;
    }
    _uniformData[0] = _lastTime = (elapsed - _timeBase).inMicroseconds / 1e6;
    // [1] stays 0 — vec2 alignment: resolution starts at byte 8.
    _uniformData[2] = target.width.toDouble();
    _uniformData[3] = target.height.toDouble();
    _uniformData[4] = _mouseX;
    _uniformData[5] = _mouseY;
    _uniformData[6] = _mouseDown;
    // [7] stays 0 — vec4 alignment: keys start at byte 32.
    // [8..11] are the keys, maintained by the key handler.
    device.queue.writeBuffer(_uniforms!, _uniformBytes);

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
    if (widget.controller?._state == this) {
      widget.controller?._state = null;
    }
    HardwareKeyboard.instance.removeHandler(_onKey);
    _bind?.dispose();
    _pipeline?.dispose();
    _fragmentModule?.dispose();
    _vertexModule?.dispose();
    _uniforms?.dispose();
    // The shared device is app-lifetime; never disposed here.
    super.dispose();
  }

  Widget _defaultOverlay(String error) {
    return Container(
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
            style: const TextStyle(color: Color(0xFFFFB4B4), fontSize: 11),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return WebGpuBuilder(
      loadingBuilder: widget.loadingBuilder,
      errorBuilder: widget.errorBuilder == null
          ? null
          : (context, error) => widget.errorBuilder!(context, '$error'),
      builder: (context, device) {
        void trackMouse(Offset local) {
          _mouseX = local.dx * dpr * widget.renderScale;
          _mouseY = local.dy * dpr * widget.renderScale;
        }

        Widget view = MouseRegion(
          opaque: false,
          onHover: (e) => trackMouse(e.localPosition),
          child: Listener(
            // Opaque: receive input regardless of how the platform texture
            // underneath hit-tests.
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              _mouseDown = 1;
              trackMouse(e.localPosition);
            },
            onPointerMove: (e) => trackMouse(e.localPosition),
            onPointerUp: (_) => _mouseDown = 0,
            onPointerCancel: (_) => _mouseDown = 0,
            child: WebGpuView(
              device: device,
              controller: widget.controller?.view,
              renderScale: widget.renderScale,
              filterQuality: widget.filterQuality,
              onFrame: (target, elapsed) => _frame(device, target, elapsed),
            ),
          ),
        );
        final error = _error;
        if (error != null) {
          final overlay = widget.errorBuilder?.call(context, error) ??
              (widget.onError == null ? _defaultOverlay(error) : null);
          if (overlay != null) {
            view = Stack(fit: StackFit.expand, children: [
              view,
              IgnorePointer(child: overlay),
            ]);
          }
        }
        return view;
      },
    );
  }
}
