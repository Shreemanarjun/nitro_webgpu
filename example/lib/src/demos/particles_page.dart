import 'package:flutter/material.dart';

import '../gpu/particle_scene.dart';
import '../widgets/editor_shell.dart';
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
        CompileErrorBox(error: scene.compileError),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return EditorPageScaffold(
      title: 'GPU particles',
      render: GpuSceneView(
        key: ValueKey(_scene),
        scene: _scene!,
        ownsScene: false,
        dynamicResolution: true,
      ),
      panel: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildControls(context),
          const SizedBox(height: 8),
          Expanded(
            child: ShaderEditorField(
              controller: _editor,
              hint: 'WGSL compute kernel — entry `simulate`, '
                  'Particle {pos, vel} storage at @binding(1), SimParams '
                  '{dt, time, count, size} at @binding(0)',
            ),
          ),
        ],
      ),
    );
  }
}
