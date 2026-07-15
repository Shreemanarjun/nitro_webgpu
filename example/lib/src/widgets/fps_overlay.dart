import 'package:flutter/material.dart';

/// One published snapshot of a view's frame statistics.
class PerfStats {
  const PerfStats({
    this.fps = 0,
    this.frameMs = 0,
    this.frameMsMax = 0,
    this.encodeMs = 0,
    this.gpuMs,
    this.gpuIsExact = false,
  });

  /// Presented frames per second (rolling ~2 s window).
  final double fps;

  /// Average present-to-present interval in the window, ms.
  final double frameMs;

  /// Worst present-to-present interval in the window, ms.
  final double frameMsMax;

  /// Average CPU time spent in the scene's encode+submit callback, ms.
  final double encodeMs;

  /// GPU pass time, ms. Exact (timestamp queries) when [gpuIsExact], else a
  /// sampled queue-drain estimate. Measured every ~30th frame; null until
  /// the first sample.
  final double? gpuMs;

  /// True when [gpuMs] is a real on-GPU timestamp-query measurement.
  final bool gpuIsExact;
}

/// Rolling per-view performance measurement.
///
/// Call [tick] once per presented frame with the CPU encode duration and an
/// optional sampled GPU drain latency; [stats] publishes at most 4×/second.
class PerfTracker {
  final ValueNotifier<PerfStats> stats = ValueNotifier(const PerfStats());

  final List<int> _frameTimesUs = <int>[];
  final List<double> _encodeMs = <double>[];
  double? _lastGpuMs;
  bool _lastGpuIsExact = false;
  int _lastPublishMs = 0;
  bool _disposed = false;

  void tick({required double encodeMs, double? gpuMs, bool gpuIsExact = false}) {
    // A frame may still be in flight when the owning view unmounts.
    if (_disposed) return;
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    _frameTimesUs.add(nowUs);
    _encodeMs.add(encodeMs);
    if (gpuMs != null) {
      _lastGpuMs = gpuMs;
      _lastGpuIsExact = gpuIsExact;
    }
    while (_frameTimesUs.length > 240 ||
        (_frameTimesUs.isNotEmpty && nowUs - _frameTimesUs.first > 2000000)) {
      _frameTimesUs.removeAt(0);
      if (_encodeMs.length > _frameTimesUs.length) _encodeMs.removeAt(0);
    }

    final nowMs = nowUs ~/ 1000;
    if (_frameTimesUs.length >= 2 && nowMs - _lastPublishMs >= 250) {
      _lastPublishMs = nowMs;
      final spanUs = _frameTimesUs.last - _frameTimesUs.first;
      final frames = _frameTimesUs.length - 1;
      var worstUs = 0;
      for (var i = 1; i < _frameTimesUs.length; i++) {
        final dt = _frameTimesUs[i] - _frameTimesUs[i - 1];
        if (dt > worstUs) worstUs = dt;
      }
      final avgEncode = _encodeMs.isEmpty
          ? 0.0
          : _encodeMs.reduce((a, b) => a + b) / _encodeMs.length;
      stats.value = PerfStats(
        fps: frames * 1e6 / spanUs,
        frameMs: spanUs / frames / 1000.0,
        frameMsMax: worstUs / 1000.0,
        encodeMs: avgEncode,
        gpuMs: _lastGpuMs,
        gpuIsExact: _lastGpuIsExact,
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stats.dispose();
  }
}

/// Top-left performance chip: FPS on the first line, frame/encode/GPU timing
/// on the second.
class PerfOverlay extends StatelessWidget {
  const PerfOverlay({super.key, required this.tracker, this.detailed = true});

  final PerfTracker tracker;

  /// When false only the FPS line is shown (compact tiles).
  final bool detailed;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Colors.greenAccent,
      fontSize: 11,
      height: 1.3,
      fontFeatures: [FontFeature.tabularFigures()],
      fontFamily: 'monospace',
    );
    return ValueListenableBuilder<PerfStats>(
      valueListenable: tracker.stats,
      builder: (context, s, _) {
        final lines = StringBuffer('${s.fps.toStringAsFixed(1)} FPS');
        if (detailed && s.frameMs > 0) {
          lines.write('\nframe ${s.frameMs.toStringAsFixed(1)}ms '
              '(max ${s.frameMsMax.toStringAsFixed(0)})');
          lines.write('\nenc ${s.encodeMs.toStringAsFixed(2)}ms');
          if (s.gpuMs != null) {
            final approx = s.gpuIsExact ? '' : '~';
            lines.write('  gpu $approx${s.gpuMs!.toStringAsFixed(2)}ms');
          }
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text('$lines', style: style),
          ),
        );
      },
    );
  }
}
