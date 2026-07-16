import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../api/gpu.dart';
import '../nitro_webgpu_present.native.dart';

/// Embeds WebGPU-rendered content in the widget tree.
///
/// Every frame, [onFrame] receives a [GpuRenderTarget] to render into using
/// the regular nitro_webgpu API (create a render pass on `target.view`,
/// submit on the device's queue). Frames are paced drop-latest: if the
/// previous frame's readback is still in flight, the tick is skipped.
class WebGpuView extends StatefulWidget {
  const WebGpuView({
    super.key,
    required this.device,
    required this.onFrame,
    this.filterQuality = FilterQuality.low,
    this.renderScale = 1.0,
  });

  /// The device to render with (owned by the caller; not disposed here).
  final GpuDevice device;

  /// Called each frame with the target to render into and the elapsed time
  /// since the view appeared. Must record + submit synchronously or await
  /// only GPU-fast futures — the frame is presented when it returns.
  final FutureOr<void> Function(GpuRenderTarget target, Duration elapsed)
      onFrame;

  final FilterQuality filterQuality;

  /// Render-resolution multiplier relative to the widget's physical pixel
  /// size (clamped to 0.1–2.0). Fragment-bound content scales roughly
  /// linearly with pixel count — 0.5 renders a quarter of the pixels.
  final double renderScale;

  @override
  State<WebGpuView> createState() => _WebGpuViewState();
}

class _WebGpuViewState extends State<WebGpuView>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  int _token = 0;
  // -1 = not created yet. 0 is a VALID id — Android's texture registry
  // hands out 0 for the first texture in the process.
  int _textureId = -1;
  GpuTextureFormat _format = GpuTextureFormat.bgra8Unorm;
  int _widthPx = 0;   // render resolution (scaled)
  int _heightPx = 0;
  int _surfaceW = 0;  // on-screen physical size (unscaled)
  int _surfaceH = 0;
  bool _frameInFlight = false;
  bool _disposed = false;
  // Surface changes requested while a frame is in flight — applied at the
  // frame boundary. Swapping the platform surface mid-frame destroys the
  // texture view the frame is rendering into (native crash on Android).
  int? _pendingSurfaceW;
  int? _pendingSurfaceH;

  void _applySurfaceSize(int surfaceW, int surfaceH) {
    _surfaceW = surfaceW;
    _surfaceH = surfaceH;
    NitroWebgpuPresent.instance
        .presenterSetSurfaceSize(_token, surfaceW, surfaceH);
  }

  void _ensurePresenter(
      int widthPx, int heightPx, int surfaceW, int surfaceH) {
    if (_token != 0) {
      // Surface (widget box) changes are rare; render-size changes (dynamic
      // resolution) are cheap and never touch the platform surface.
      if (surfaceW != _surfaceW || surfaceH != _surfaceH) {
        if (_frameInFlight) {
          _pendingSurfaceW = surfaceW;
          _pendingSurfaceH = surfaceH;
        } else {
          _applySurfaceSize(surfaceW, surfaceH);
        }
      }
      if (widthPx != _widthPx || heightPx != _heightPx) {
        _widthPx = widthPx;
        _heightPx = heightPx;
        NitroWebgpuPresent.instance
            .resizePresenter(_token, widthPx, heightPx);
      }
      return;
    }
    _widthPx = widthPx;
    _heightPx = heightPx;
    _surfaceW = surfaceW;
    _surfaceH = surfaceH;
    final token = NitroWebgpuPresent.instance.createPresenter(
        widget.device.debugAddress, widthPx, heightPx);
    if (token == 0) return;
    _token = token;
    if (surfaceW != widthPx || surfaceH != heightPx) {
      NitroWebgpuPresent.instance
          .presenterSetSurfaceSize(token, surfaceW, surfaceH);
    }
    _textureId = NitroWebgpuPresent.instance.flutterTextureId(token);
    final raw = NitroWebgpuPresent.instance.presenterFormat(token);
    _format = GpuTextureFormat.values.firstWhere(
      (f) => f.raw == raw,
      orElse: () => GpuTextureFormat.bgra8Unorm,
    );
    _ticker = createTicker(_tick)..start();
    // The texture id became known during layout; schedule a rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _tick(Duration elapsed) async {
    if (_token == 0 || _frameInFlight) return;
    _frameInFlight = true;
    try {
      final viewAddress =
          await NitroWebgpuPresent.instance.acquireFrame(_token);
      if (viewAddress == 0 || !mounted || _token == 0) return;
      final target = GpuRenderTarget(
        view: GpuTextureView.borrowed(viewAddress),
        width: _widthPx,
        height: _heightPx,
        targetFormat: _format,
      );
      try {
        await widget.onFrame(target, elapsed);
      } finally {
        // Always recycle the acquired slot — leaking it would shrink the
        // ring permanently (a stale present on an error path is the lesser
        // evil, and onFrame contracts to always draw).
        if (_token != 0) {
          NitroWebgpuPresent.instance.presentFrame(_token);
        }
      }
    } finally {
      _frameInFlight = false;
      // Deferred work that must not run mid-frame: a surface swap requested
      // during this frame, or a dispose that arrived while rendering.
      if (_disposed) {
        _destroyNow();
      } else if (_pendingSurfaceW != null && _token != 0) {
        _applySurfaceSize(_pendingSurfaceW!, _pendingSurfaceH!);
        _pendingSurfaceW = null;
        _pendingSurfaceH = null;
      }
    }
  }

  void _destroyNow() {
    if (_token == 0) return;
    final token = _token;
    _token = 0;
    // Drains in-flight GPU work, then unregisters the Flutter texture.
    unawaited(NitroWebgpuPresent.instance.destroyPresenter(token));
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _disposed = true;
    // Mid-frame dispose defers to the frame boundary — tearing the
    // presenter down while onFrame encodes into its view is a native crash.
    if (!_frameInFlight) _destroyNow();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final scale = widget.renderScale.clamp(0.1, 2.0);
    return LayoutBuilder(builder: (context, constraints) {
      final surfaceW = (constraints.maxWidth * dpr).round();
      final surfaceH = (constraints.maxHeight * dpr).round();
      final w = (constraints.maxWidth * dpr * scale).round();
      final h = (constraints.maxHeight * dpr * scale).round();
      if (w > 0 && h > 0) _ensurePresenter(w, h, surfaceW, surfaceH);
      if (_textureId < 0) return const SizedBox.expand();
      return Texture(
        textureId: _textureId,
        filterQuality: widget.filterQuality,
      );
    });
  }
}
