import 'package:flutter/material.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

import '../gpu/gpu_context.dart';
import '../gpu/pass_timer.dart';
import '../gpu/scenes.dart';
import 'fps_overlay.dart';

/// Renders a [GpuScene] live on the shared device, with a performance
/// counter (FPS, frame time, encode time, sampled GPU time) pinned to the
/// top-left corner.
///
/// Scene ownership: by default the view disposes the scene when it unmounts.
/// Pass [ownsScene] = false when the caller keeps its own reference (e.g. a
/// page that also drives the scene's controls) — the caller must dispose the
/// scene itself, after this view has unmounted.
class GpuSceneView extends StatefulWidget {
  const GpuSceneView({
    super.key,
    required this.scene,
    this.ownsScene = true,
    this.showPerf = true,
    this.detailedPerf = true,
  });

  final GpuScene scene;
  final bool ownsScene;
  final bool showPerf;

  /// When false only the FPS line is shown (compact grid tiles).
  final bool detailedPerf;

  @override
  State<GpuSceneView> createState() => _GpuSceneViewState();
}

class _GpuSceneViewState extends State<GpuSceneView> {
  final PerfTracker _perf = PerfTracker();
  GpuContext? _ctx;
  GpuPassTimer? _timer;
  String? _error;
  int _frameIndex = 0;

  @override
  void initState() {
    super.initState();
    GpuContext.obtain().then((ctx) async {
      final timer = await GpuPassTimer.create(ctx.device);
      if (!mounted) {
        timer?.dispose();
        return;
      }
      setState(() {
        _ctx = ctx;
        _timer = timer;
      });
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  Future<void> _onFrame(GpuRenderTarget target, Duration elapsed) async {
    _frameIndex++;
    final sample = _frameIndex % 30 == 0;

    // Real on-GPU pass timing via timestamp queries; falls back to sampling
    // the queue-drain latency when the feature is unavailable.
    final timestamps = sample ? _timer?.begin() : null;

    final encode = Stopwatch()..start();
    await widget.scene
        .render(_ctx!.device, target, elapsed, timestamps: timestamps);
    encode.stop();

    double? gpuMs;
    var gpuIsExact = false;
    if (timestamps != null) {
      gpuMs = await _timer!.finish();
      gpuIsExact = gpuMs != null;
    } else if (sample && _timer == null) {
      final drain = Stopwatch()..start();
      await _ctx!.device.queue.onSubmittedWorkDone();
      drain.stop();
      gpuMs = drain.elapsedMicroseconds / 1000.0;
    }
    _perf.tick(
      encodeMs: encode.elapsedMicroseconds / 1000.0,
      gpuMs: gpuMs,
      gpuIsExact: gpuIsExact,
    );
  }

  @override
  void dispose() {
    if (widget.ownsScene) {
      widget.scene.dispose();
    }
    _timer?.dispose();
    _perf.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text('GPU unavailable: $_error'));
    }
    final ctx = _ctx;
    if (ctx == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        WebGpuView(device: ctx.device, onFrame: _onFrame),
        if (widget.showPerf)
          Positioned(
            top: 8,
            left: 8,
            child: PerfOverlay(tracker: _perf, detailed: widget.detailedPerf),
          ),
      ],
    );
  }
}
