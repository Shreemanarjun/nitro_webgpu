import 'package:flutter/foundation.dart';

import '../widgets/fps_overlay.dart';

/// Console logging of per-view GPU performance — grep for `[gpu-perf]`.
///
/// One line per labeled view per second, machine-parseable:
/// ```
/// [gpu-perf] label=plasma fps=59.9 frame_ms=16.68 frame_max_ms=18 enc_ms=0.31 gpu_ms=0.42 gpu_exact=true
/// ```
abstract final class PerfLog {
  /// Global switch; on by default in debug builds only.
  static bool enabled = kDebugMode;

  static final Map<String, int> _lastLogMs = {};

  static void record(String label, PerfStats s) {
    if (!enabled || s.frameMs <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (_lastLogMs[label] ?? 0) < 1000) return;
    _lastLogMs[label] = now;
    final gpu = s.gpuMs == null
        ? ''
        : ' gpu_ms=${s.gpuMs!.toStringAsFixed(3)} gpu_exact=${s.gpuIsExact}';
    debugPrint('[gpu-perf] label=$label '
        'fps=${s.fps.toStringAsFixed(1)} '
        'frame_ms=${s.frameMs.toStringAsFixed(2)} '
        'frame_max_ms=${s.frameMsMax.toStringAsFixed(0)} '
        'enc_ms=${s.encodeMs.toStringAsFixed(2)}$gpu');
  }
}
