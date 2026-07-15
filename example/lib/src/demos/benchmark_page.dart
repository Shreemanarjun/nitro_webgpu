import 'dart:async';

import 'package:flutter/material.dart';

import '../gpu/benchmark_scenes.dart';
import '../widgets/fps_overlay.dart';
import '../widgets/gpu_scene_view.dart';

/// Performance benchmark: four deliberately heavy scenes.
///
/// Grid mode shows all four rendering simultaneously (contention check);
/// the sequential run gives each scene the whole GPU for a few seconds and
/// reports averaged FPS / frame / encode / GPU-timestamp numbers, also
/// logged as `[gpu-bench]` lines for offline comparison.
class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key});

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

enum _Mode { grid, running, results }

class _BenchResult {
  const _BenchResult({
    required this.name,
    required this.fps,
    required this.frameMs,
    required this.encodeMs,
    required this.gpuMs,
  });

  final String name;
  final double fps;
  final double frameMs;
  final double encodeMs;
  final double? gpuMs;
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  static const _warmup = Duration(seconds: 2);
  static const _measure = Duration(seconds: 5);

  final _scenes = benchmarkScenes();
  _Mode _mode = _Mode.grid;
  int _runIndex = 0;
  DateTime _sceneStart = DateTime.now();
  final List<PerfStats> _samples = [];
  final List<_BenchResult> _results = [];
  Timer? _advanceTimer;

  void _startRun() {
    _results.clear();
    _runIndex = 0;
    _beginScene();
    setState(() => _mode = _Mode.running);
  }

  void _beginScene() {
    _samples.clear();
    _sceneStart = DateTime.now();
    _advanceTimer?.cancel();
    _advanceTimer = Timer(_warmup + _measure, _finishScene);
  }

  void _collect(PerfStats stats) {
    if (_mode != _Mode.running) return;
    if (DateTime.now().difference(_sceneStart) < _warmup) return;
    _samples.add(stats);
  }

  void _finishScene() {
    if (!mounted) return;
    final name = _scenes[_runIndex].$1;
    final samples = List<PerfStats>.of(_samples);
    double avg(double Function(PerfStats) f) => samples.isEmpty
        ? 0
        : samples.map(f).reduce((a, b) => a + b) / samples.length;
    final gpuSamples =
        samples.map((s) => s.gpuMs).whereType<double>().toList();
    final result = _BenchResult(
      name: name,
      fps: avg((s) => s.fps),
      frameMs: avg((s) => s.frameMs),
      encodeMs: avg((s) => s.encodeMs),
      gpuMs: gpuSamples.isEmpty
          ? null
          : gpuSamples.reduce((a, b) => a + b) / gpuSamples.length,
    );
    _results.add(result);
    debugPrint('[gpu-bench] scene=${result.name} '
        'fps=${result.fps.toStringAsFixed(1)} '
        'frame_ms=${result.frameMs.toStringAsFixed(2)} '
        'enc_ms=${result.encodeMs.toStringAsFixed(2)} '
        'gpu_ms=${result.gpuMs?.toStringAsFixed(3) ?? 'n/a'}');

    if (_runIndex + 1 < _scenes.length) {
      setState(() => _runIndex++);
      _beginScene();
    } else {
      setState(() => _mode = _Mode.results);
    }
  }

  @override
  void dispose() {
    _advanceTimer?.cancel();
    super.dispose();
  }

  Widget _buildGrid(BuildContext context) {
    return Column(children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [
              for (final (name, builder) in _scenes)
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Stack(fit: StackFit.expand, children: [
                    GpuSceneView(scene: builder(), logLabel: 'grid-$name'),
                    Positioned(
                      bottom: 6,
                      right: 10,
                      child: Text(name,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 11)),
                    ),
                  ]),
                ),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: FilledButton.icon(
          icon: const Icon(Icons.speed),
          label: const Text('Run sequential benchmark (4 × 7 s)'),
          onPressed: _startRun,
        ),
      ),
    ]);
  }

  Widget _buildRunning(BuildContext context) {
    final (name, builder) = _scenes[_runIndex];
    return Column(children: [
      // Fixed logical size so results are comparable across window sizes
      // (fragment cost is linear in pixel count).
      Expanded(
        child: Center(
          child: SizedBox(
            width: 960,
            height: 540,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: GpuSceneView(
                key: ValueKey('bench-$_runIndex'),
                scene: builder(),
                logLabel: 'bench-$name',
                onStats: _collect,
              ),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(
              child: Text(
                  'Measuring ${_runIndex + 1}/${_scenes.length}: $name')),
        ]),
      ),
    ]);
  }

  Widget _buildResults(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Results', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(
        '2 s warmup, 5 s measurement per scene at a fixed 960×540 logical '
        'size (window-size independent). GPU column is the on-GPU pass time '
        'from timestamp queries.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Scene')),
            DataColumn(label: Text('FPS'), numeric: true),
            DataColumn(label: Text('frame ms'), numeric: true),
            DataColumn(label: Text('enc ms'), numeric: true),
            DataColumn(label: Text('GPU ms'), numeric: true),
          ],
          rows: [
            for (final r in _results)
              DataRow(cells: [
                DataCell(Text(r.name)),
                DataCell(Text(r.fps.toStringAsFixed(1))),
                DataCell(Text(r.frameMs.toStringAsFixed(2))),
                DataCell(Text(r.encodeMs.toStringAsFixed(2))),
                DataCell(Text(r.gpuMs?.toStringAsFixed(3) ?? '—')),
              ]),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Row(children: [
        FilledButton.icon(
          icon: const Icon(Icons.replay),
          label: const Text('Run again'),
          onPressed: _startRun,
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: () => setState(() => _mode = _Mode.grid),
          child: const Text('Back to grid'),
        ),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Performance benchmark')),
      body: switch (_mode) {
        _Mode.grid => _buildGrid(context),
        _Mode.running => _buildRunning(context),
        _Mode.results => _buildResults(context),
      },
    );
  }
}
