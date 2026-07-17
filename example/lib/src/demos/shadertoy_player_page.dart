import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

import '../gpu/gpu_context.dart';
import '../gpu/shadertoy_engine.dart';
import '../widgets/gpu_scene_view.dart';

class _Preset {
  const _Preset({
    required this.name,
    required this.language,
    required this.image,
    this.bufferA,
    required this.imageChannels,
    this.bufferAChannels = const [
      _Chan.none, _Chan.none, _Chan.none, _Chan.none,
    ],
  });

  final String name;
  final ShadertoyLanguage language;
  final String image;
  final String? bufferA;
  final List<_Chan> imageChannels;
  final List<_Chan> bufferAChannels;
}

enum _Chan { none, bufferA, noise }

const _glslMousePreset = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 m = iMouse.xy / iResolution.xy;
    float d = distance(uv, m);
    vec3 col = 0.5 + 0.5 * cos(iTime + uv.xyx * 6.2831 + vec3(0.0, 2.0, 4.0));
    col *= 0.25 + 0.75 * smoothstep(0.0, 0.3, d);
    fragColor = vec4(col, 1.0);
}''';

const _wgslTrailsBufferA = '''
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  let prev = textureSampleLevel(iChannel0, stSampler, uv, 0.0).rgb * 0.97;
  let m = iMouse.xy / iResolution.xy;
  let d = distance(uv, m);
  let ink = exp(-d * d * 600.0);
  return vec4f(prev + vec3f(ink, ink * 0.55, ink * 0.9), 1.0);
}''';

const _wgslTrailsImage = '''
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  return vec4f(textureSampleLevel(iChannel0, stSampler, uv, 0.0).rgb, 1.0);
}''';

const _glslNoisePreset = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float n = texture(iChannel0, uv * 3.0 + vec2(iTime * 0.05, 0.0)).r;
    vec3 col = vec3(n) * (0.5 + 0.5 * cos(iTime + uv.xyx * 4.0 + vec3(0.0, 2.0, 4.0)));
    fragColor = vec4(col, 1.0);
}''';

const _presets = [
  _Preset(
    name: 'GLSL + mouse',
    language: ShadertoyLanguage.glsl,
    image: _glslMousePreset,
    imageChannels: [_Chan.none, _Chan.none, _Chan.none, _Chan.none],
  ),
  _Preset(
    name: 'Feedback trails (Buffer A)',
    language: ShadertoyLanguage.wgslSnippet,
    image: _wgslTrailsImage,
    bufferA: _wgslTrailsBufferA,
    imageChannels: [_Chan.bufferA, _Chan.none, _Chan.none, _Chan.none],
    bufferAChannels: [_Chan.bufferA, _Chan.none, _Chan.none, _Chan.none],
  ),
  _Preset(
    name: 'GLSL + noise channel',
    language: ShadertoyLanguage.glsl,
    image: _glslNoisePreset,
    imageChannels: [_Chan.noise, _Chan.none, _Chan.none, _Chan.none],
  ),
];

/// Shadertoy player: paste GLSL straight from shadertoy.com (or a WGSL
/// `mainImage` snippet), with iMouse interaction, multi-pass Buffer A
/// feedback, and texture channels.
class ShadertoyPlayerPage extends StatefulWidget {
  const ShadertoyPlayerPage({super.key});

  @override
  State<ShadertoyPlayerPage> createState() => _ShadertoyPlayerPageState();
}

class _ShadertoyPlayerPageState extends State<ShadertoyPlayerPage> {
  late final ShadertoyEngine _engine;
  late final TextEditingController _imageEditor;
  late final TextEditingController _bufferEditor;
  int _presetIndex = 0;
  int _passTab = 0; // 0 = Image, 1 = Buffer A
  ShadertoyLanguage _language = _presets[0].language;
  List<_Chan> _imageChannels = List.of(_presets[0].imageChannels);
  List<_Chan> _bufferChannels = List.of(_presets[0].bufferAChannels);
  bool _paused = false;

  GpuTexture? _noiseTexture; // created lazily from the shared device

  @override
  void initState() {
    super.initState();
    final p = _presets[0];
    _engine = ShadertoyEngine(
        image: ShadertoyPassSpec(language: p.language, source: p.image));
    _imageEditor = TextEditingController(text: p.image);
    _bufferEditor = TextEditingController(text: p.bufferA ?? '');
    _apply();
  }

  @override
  void dispose() {
    _engine.dispose();
    _noiseTexture?.dispose();
    _imageEditor.dispose();
    _bufferEditor.dispose();
    super.dispose();
  }

  Future<void> _ensureNoise() async {
    if (_noiseTexture != null) return;
    final ctx = await GpuContext.obtain();
    const size = 256;
    final rng = math.Random(7);
    final bytes = Uint8List(size * size * 4);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    final tex = ctx.device.createTexture(
      width: size,
      height: size,
      format: GpuTextureFormat.rgba8Unorm,
      usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
      label: 'shadertoy-noise',
    );
    ctx.queue.writeTexture(tex, bytes);
    _noiseTexture = tex;
  }

  Future<ShadertoyChannel> _channel(_Chan c) async {
    switch (c) {
      case _Chan.none:
        return const ShadertoyChannel.none();
      case _Chan.bufferA:
        return const ShadertoyChannel.buffer(ShadertoyChannelKind.bufferA);
      case _Chan.noise:
        await _ensureNoise();
        return ShadertoyChannel.image(_noiseTexture!);
    }
  }

  Future<void> _apply() async {
    final imageChannels = [for (final c in _imageChannels) await _channel(c)];
    _engine.setPass(
        4,
        ShadertoyPassSpec(
            language: _language,
            source: _imageEditor.text,
            channels: imageChannels));
    if (_bufferEditor.text.trim().isNotEmpty) {
      final bufferChannels = [
        for (final c in _bufferChannels) await _channel(c)
      ];
      _engine.setPass(
          0,
          ShadertoyPassSpec(
              language: _language,
              source: _bufferEditor.text,
              channels: bufferChannels));
    }
  }

  void _loadPreset(int index) async {
    final p = _presets[index];
    setState(() {
      _presetIndex = index;
      _language = p.language;
      _imageEditor.text = p.image;
      _bufferEditor.text = p.bufferA ?? '';
      _imageChannels = List.of(p.imageChannels);
      _bufferChannels = List.of(p.bufferAChannels);
      _passTab = 0;
    });
    await _apply();
  }

  List<_Chan> get _currentChannels =>
      _passTab == 0 ? _imageChannels : _bufferChannels;

  Widget _buildControls(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (var i = 0; i < _presets.length; i++)
              ChoiceChip(
                label: Text(_presets[i].name),
                selected: _presetIndex == i,
                onSelected: (_) => _loadPreset(i),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Image')),
                ButtonSegment(value: 1, label: Text('Buffer A')),
              ],
              selected: {_passTab},
              onSelectionChanged: (s) => setState(() => _passTab = s.first),
            ),
            const SizedBox(width: 12),
            SegmentedButton<ShadertoyLanguage>(
              segments: const [
                ButtonSegment(
                    value: ShadertoyLanguage.glsl, label: Text('GLSL')),
                ButtonSegment(
                    value: ShadertoyLanguage.wgslSnippet, label: Text('WGSL')),
              ],
              selected: {_language},
              onSelectionChanged: (s) =>
                  setState(() => _language = s.first),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Text('channels ', style: TextStyle(fontSize: 12)),
            for (var c = 0; c < 4; c++)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: DropdownButton<_Chan>(
                  value: _currentChannels[c],
                  isDense: true,
                  items: const [
                    DropdownMenuItem(value: _Chan.none, child: Text('—')),
                    DropdownMenuItem(value: _Chan.bufferA, child: Text('BufA')),
                    DropdownMenuItem(value: _Chan.noise, child: Text('noise')),
                  ],
                  onChanged: (v) =>
                      setState(() => _currentChannels[c] = v ?? _Chan.none),
                ),
              ),
            const Spacer(),
            IconButton.filledTonal(
              icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
              onPressed: () => setState(() {
                _paused = !_paused;
                _engine.paused = _paused;
              }),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              icon: const Icon(Icons.bolt),
              label: const Text('Run'),
              onPressed: _apply,
            ),
          ],
        ),
        ValueListenableBuilder<String?>(
          valueListenable: _engine.compileError,
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

  Widget _buildEditor(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: TextField(
        controller: _passTab == 0 ? _imageEditor : _bufferEditor,
        maxLines: null,
        expands: true,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.all(12),
          border: InputBorder.none,
          hintText: _language == ShadertoyLanguage.glsl
              ? 'GLSL from shadertoy.com: void mainImage(out vec4 fragColor, '
                  'in vec2 fragCoord) { ... } — iTime/iResolution/iMouse/'
                  'iChannel0..3 available'
              : 'WGSL snippet: fn mainImage(fragCoord: vec2f) -> vec4f '
                  '{ ... } — iTime/iResolution/iMouse/iChannel0..3 available',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final render = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: LayoutBuilder(builder: (context, box) {
        return GestureDetector(
          onPanDown: (d) => _engine.setMouseNormalized(
              d.localPosition.dx / box.maxWidth,
              d.localPosition.dy / box.maxHeight,
              press: true),
          onPanUpdate: (d) => _engine.setMouseNormalized(
              d.localPosition.dx / box.maxWidth,
              d.localPosition.dy / box.maxHeight),
          child: GpuSceneView(
            scene: _engine,
            ownsScene: false,
            dynamicResolution: true,
          ),
        );
      }),
    );
    final panel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildControls(context),
        const SizedBox(height: 8),
        Expanded(child: _buildEditor(context)),
      ],
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Shadertoy player')),
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
