import 'package:flutter/material.dart';

import '../gpu/particle_scene.dart';
import '../widgets/gpu_scene_view.dart';

/// GPU particles: a compute kernel (editable) integrates a storage buffer of
/// particles every frame; an instanced render pass draws them without the
/// positions ever leaving the GPU.
class ParticlesPage extends StatefulWidget {
  const ParticlesPage({super.key});

  @override
  State<ParticlesPage> createState() => _ParticlesPageState();
}

class _ParticlesPageState extends State<ParticlesPage> {
  ParticleScene? _scene;
  late final TextEditingController _editor;
  int _count = 20000;
  bool _paused = false;

  static const _counts = [2000, 20000, 100000];

  @override
  void initState() {
    super.initState();
    _editor = TextEditingController(text: defaultParticleKernel);
    _rebuildScene();
  }

  void _rebuildScene() {
    _scene?.dispose();
    _scene = ParticleScene(count: _count)
      ..paused = _paused
      ..setKernel(_editor.text);
    setState(() {});
  }

  @override
  void dispose() {
    _scene?.dispose();
    _editor.dispose();
    super.dispose();
  }

  Widget _buildControls(BuildContext context) {
    final scene = _scene!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Wrap, not Row: chips + buttons overflow narrow (phone) layouts.
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final c in _counts)
              ChoiceChip(
                label: Text('${c ~/ 1000}k'),
                selected: _count == c,
                onSelected: (_) {
                  _count = c;
                  _rebuildScene();
                },
              ),
            IconButton.filledTonal(
              icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
              onPressed: () => setState(() {
                _paused = !_paused;
                scene.paused = _paused;
              }),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.bolt),
              label: const Text('Run kernel'),
              onPressed: () => scene.setKernel(_editor.text),
            ),
          ],
        ),
        ValueListenableBuilder<String?>(
          valueListenable: scene.compileError,
          builder: (context, error, _) => error == null
              ? const SizedBox.shrink()
              : Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(8),
                  constraints: const BoxConstraints(maxHeight: 140),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border:
                        Border.all(color: Colors.red.withValues(alpha: 0.5)),
                  ),
                  child: SingleChildScrollView(
                    child: Text(error,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11)),
                  ),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final render = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: GpuSceneView(
        key: ValueKey(_scene),
        scene: _scene!,
        ownsScene: false,
        dynamicResolution: true,
      ),
    );
    final panel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildControls(context),
        const SizedBox(height: 8),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: TextField(
              controller: _editor,
              maxLines: null,
              expands: true,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.all(12),
                border: InputBorder.none,
                hintText: 'WGSL compute kernel — entry `simulate`, '
                    'Particle {pos, vel} storage at @binding(1), SimParams '
                    '{dt, time, count, size} at @binding(0)',
              ),
            ),
          ),
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(title: const Text('GPU particles')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth > 900) {
            return Row(children: [
              Expanded(flex: 3, child: render),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: panel),
            ]);
          }
          return Column(children: [
            Expanded(flex: 3, child: render),
            const SizedBox(height: 12),
            Expanded(flex: 4, child: panel),
          ]);
        }),
      ),
    );
  }
}
