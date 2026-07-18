import 'package:flutter/material.dart';

import '../gpu/shader_presets.dart';
import '../gpu/shader_toy_scene.dart';
import '../widgets/editor_shell.dart';
import '../widgets/gpu_scene_view.dart';

/// WGSL shader toy: live render on the left, editable WGSL + controls on the
/// right. Compile errors from naga (with line/column info) appear inline —
/// the previous shader keeps rendering until the new one is valid.
class ShaderToyPage extends StatefulWidget {
  const ShaderToyPage({super.key});

  @override
  State<ShaderToyPage> createState() => _ShaderToyPageState();
}

class _ShaderToyPageState extends State<ShaderToyPage> {
  late final ShaderToyScene _scene;
  late final TextEditingController _editor;
  int _presetIndex = 0;
  double _speed = 1.0;
  double _param = 0.5;
  double _renderScale = 1.0;
  bool _autoRes = true;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _scene = ShaderToyScene(source: shaderPresets[0].source)
      ..timeScale = _speed
      ..paramValue = _param;
    _editor = TextEditingController(text: shaderPresets[0].source);
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

  void _loadPreset(int index) {
    setState(() {
      _presetIndex = index;
      _editor.text = shaderPresets[index].source;
    });
    _scene.setSource(shaderPresets[index].source);
  }

  Widget _buildControls(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (var i = 0; i < shaderPresets.length; i++)
              ChoiceChip(
                label: Text(shaderPresets[i].name),
                selected: _presetIndex == i,
                onSelected: (_) => _loadPreset(i),
              ),
          ],
        ),
        const SizedBox(height: 4),
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
            const SizedBox(width: 52, child: Text('param')),
            Expanded(
              child: Slider(
                value: _param,
                onChanged: (v) => setState(() {
                  _param = v;
                  _scene.paramValue = v;
                }),
              ),
            ),
            SizedBox(width: 36, child: Text(_param.toStringAsFixed(2))),
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
                onChanged: _autoRes
                    ? null
                    : (v) => setState(() => _renderScale = v),
              ),
            ),
            SizedBox(
              width: 76,
              child: Row(children: [
                Checkbox(
                  value: _autoRes,
                  onChanged: (v) =>
                      setState(() => _autoRes = v ?? true),
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
              label: const Text('Apply shader'),
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
      title: 'WGSL shader toy',
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
              hint: 'WGSL — must export vs_main/fs_main and bind '
                  'struct U { time, width, height, param } at '
                  '@group(0) @binding(0)',
            ),
          ),
        ],
      ),
    );
  }
}
