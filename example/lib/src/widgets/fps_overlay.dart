import 'package:flutter/material.dart';

/// Rolling FPS measurement over the last ~2 seconds of presented frames.
/// Call [tick] once per presented frame; [fps] publishes at most 4×/second.
class FpsTracker {
  final ValueNotifier<double> fps = ValueNotifier(0);
  final List<int> _frameTimesMs = <int>[];
  int _lastPublishMs = 0;

  void tick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _frameTimesMs.add(now);
    while (_frameTimesMs.length > 240 ||
        (_frameTimesMs.isNotEmpty && now - _frameTimesMs.first > 2000)) {
      _frameTimesMs.removeAt(0);
    }
    if (_frameTimesMs.length >= 2 && now - _lastPublishMs >= 250) {
      _lastPublishMs = now;
      final spanMs = now - _frameTimesMs.first;
      fps.value = (_frameTimesMs.length - 1) * 1000.0 / spanMs;
    }
  }

  void dispose() => fps.dispose();
}

/// The top-left FPS chip shown over live render views.
class FpsOverlay extends StatelessWidget {
  const FpsOverlay({super.key, required this.tracker});

  final FpsTracker tracker;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: tracker.fps,
      builder: (context, fps, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            '${fps.toStringAsFixed(1)} FPS',
            style: const TextStyle(
              color: Colors.greenAccent,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }
}
