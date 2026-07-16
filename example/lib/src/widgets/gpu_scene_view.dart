import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

import '../gpu/gpu_context.dart';
import '../gpu/pass_timer.dart';
import '../gpu/perf_log.dart';
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
    this.logLabel,
    this.onStats,
    this.renderScale = 1.0,
    this.dynamicResolution = false,
    this.targetFps,
  });

  /// Render-resolution multiplier (see [WebGpuView.renderScale]).
  final double renderScale;

  /// Dynamic resolution scaling: uses the exact per-pass GPU timings to
  /// steer the internal render scale so the scene holds [targetFps]
  /// regardless of window size (like games do). The overlay shows the
  /// current `res N.NN×` when scaled down. Requires timestamp queries;
  /// no-op on the estimate fallback.
  final bool dynamicResolution;

  /// Frame-rate target for [dynamicResolution]. Null (default) targets the
  /// display's actual refresh rate — 120 on ProMotion, 60 elsewhere —
  /// re-read when the window moves between monitors.
  final int? targetFps;

  final GpuScene scene;
  final bool ownsScene;
  final bool showPerf;

  /// When false only the FPS line is shown (compact grid tiles).
  final bool detailedPerf;

  /// When set, stats are logged to the console once per second as
  /// `[gpu-perf] label=<logLabel> …` lines (see [PerfLog]).
  final String? logLabel;

  /// Invoked on every stats publish (~4×/second) — used by the benchmark
  /// runner to collect samples.
  final void Function(PerfStats stats)? onStats;

  @override
  State<GpuSceneView> createState() => _GpuSceneViewState();
}

class _GpuSceneViewState extends State<GpuSceneView> {
  final PerfTracker _perf = PerfTracker();
  GpuContext? _ctx;
  GpuPassTimer? _timer;
  String? _error;
  int _frameIndex = 0;
  double _dynScale = 1.0;
  double _displayFps = 60;

  double get _targetFps =>
      widget.targetFps?.toDouble() ??
      (GpuContext.displayRefreshRate > _displayFps
          ? GpuContext.displayRefreshRate
          : _displayFps);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final rate = View.of(context).display.refreshRate;
    if (rate > 0) _displayFps = rate;
  }
  // Sample the GPU cost every N frames: quickly while over budget (fast DRS
  // convergence at low fps), sparsely once settled (each sample briefly
  // stalls the pipeline for the readback).
  int _sampleInterval = 10;

  double get _effectiveScale =>
      (widget.renderScale * (widget.dynamicResolution ? _dynScale : 1.0))
          .clamp(0.1, 2.0);

  /// Closed-loop control: GPU cost is ~linear in pixel count, so the scale
  /// correction is the square root of budget/actual.
  ///
  /// Asymmetric on purpose: scale down fast when over budget (dropped frames
  /// hurt), scale back up slowly and only when comfortably under budget —
  /// every scale change is a visible resample step, so upscale thrash reads
  /// as flicker.
  void _steerResolution(double gpuMs) {
    if (!widget.dynamicResolution || gpuMs <= 0) return;
    const headroom = 0.85;
    final budgetMs = 1000.0 / _targetFps * headroom;
    final ratio = budgetMs / gpuMs;
    _sampleInterval = ratio < 0.85 ? 10 : 30;
    // Dead-band: within ±15% of budget (or already at 1.0 and under budget),
    // leave the scale alone.
    if (ratio > 0.85 && (ratio < 1.15 || _dynScale >= 1.0)) return;
    final ideal = (_dynScale * math.sqrt(ratio)).clamp(0.25, 1.0);
    final gain = ideal < _dynScale ? 0.6 : 0.2;
    final damped = _dynScale + (ideal - _dynScale) * gain;
    if ((damped - _dynScale).abs() > 0.03) {
      setState(() => _dynScale = damped);
    }
  }

  void _onStatsPublished() {
    final stats = _perf.stats.value;
    final label = widget.logLabel;
    if (label != null) PerfLog.record(label, stats);
    widget.onStats?.call(stats);
  }

  @override
  void initState() {
    super.initState();
    _perf.stats.addListener(_onStatsPublished);
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
    final sample = _frameIndex % _sampleInterval == 0;

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
      if (gpuMs != null && mounted) _steerResolution(gpuMs);
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
      scale: _effectiveScale,
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
        WebGpuView(
          device: ctx.device,
          onFrame: _onFrame,
          renderScale: _effectiveScale,
        ),
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
