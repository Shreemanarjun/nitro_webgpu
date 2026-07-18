import 'package:flutter/material.dart';

import '../widgets/editor_shell.dart';
import '../widgets/gpu_scene_view.dart';
import 'custom_shader.dart';

/// Compute shader toy: paste a Slang-playground-style COMPUTE kernel
/// (`imageMain` writing a `texture_storage_2d<rgba8unorm, write>`) and run
/// it live. Same editor contract as the WGSL shader toy — naga compile
/// errors appear inline and the previous kernel keeps rendering until the
/// new one is valid.
class ComputeToyPage extends StatefulWidget {
  const ComputeToyPage({super.key});

  @override
  State<ComputeToyPage> createState() => _ComputeToyPageState();
}

class _ComputeToyPageState extends State<ComputeToyPage> {
  late final SlangComputeScene _scene;
  late final TextEditingController _editor;
  double _speed = 1.0;
  double _renderScale = 1.0;
  bool _autoRes = true;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _scene = SlangComputeScene(source: customShader)..timeScale = _speed;
    _editor = TextEditingController(text: customShader);
  }

  @override
  void dispose() {
    // The page owns the scene (GpuSceneView gets ownsScene: false) because
    // build() subscribes to _scene.compileError — the scene must outlive the
    // view. Children unmount before this dispose runs, so this is safe.
    _scene.dispose();
    _editor.dispose();
    super.dispose();
  }

  Widget _buildControls(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox(width: 52, child: Text('speed')),
            Expanded(
              child: Slider(
                value: _speed,
                min: 0.0,
                max: 3.0,
                onChanged: (v) => setState(() {
                  _speed = v;
                  _scene.timeScale = v;
                }),
              ),
            ),
            SizedBox(width: 36, child: Text('${_speed.toStringAsFixed(1)}×')),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 52, child: Text('res')),
            Expanded(
              child: Slider(
                value: _renderScale,
                min: 0.25,
                max: 1.0,
                divisions: 6,
                onChanged:
                    _autoRes ? null : (v) => setState(() => _renderScale = v),
              ),
            ),
            SizedBox(
              width: 76,
              child: Row(children: [
                Checkbox(
                  value: _autoRes,
                  onChanged: (v) => setState(() => _autoRes = v ?? true),
                ),
                const Text('auto', style: TextStyle(fontSize: 12)),
              ]),
            ),
          ],
        ),
        Row(
          children: [
            IconButton.filledTonal(
              icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
              tooltip: _paused ? 'Resume' : 'Pause',
              onPressed: () => setState(() {
                _paused = !_paused;
                _scene.paused = _paused;
              }),
            ),
            const Spacer(),
            FilledButton.icon(
              icon: const Icon(Icons.bolt),
              label: const Text('Run kernel'),
              onPressed: () => _scene.setSource(_editor.text),
            ),
          ],
        ),
        CompileErrorBox(error: _scene.compileError),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return EditorPageScaffold(
      title: 'Compute shader toy',
      render: GpuSceneView(
        scene: _scene,
        ownsScene: false,
        renderScale: _autoRes ? 1.0 : _renderScale,
        dynamicResolution: _autoRes,
      ),
      panel: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildControls(context),
          const SizedBox(height: 8),
          Expanded(
            child: ShaderEditorField(
              controller: _editor,
              hint: 'WGSL compute kernel — entry point `imageMain`, uniforms '
                  '{ time, frame } at @group(0) @binding(0), output '
                  'texture_storage_2d<rgba8unorm, write> at @binding(1) '
                  '(the Slang playground convention)',
            ),
          ),
        ],
      ),
    );
  }
}
