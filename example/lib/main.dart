import 'dart:async';

import 'package:flutter/material.dart';

import 'src/demos/adapter_probe_page.dart';
import 'src/demos/benchmark_page.dart';
import 'src/demos/compute_page.dart';
import 'src/demos/compute_toy_page.dart';
import 'src/demos/particles_page.dart';
import 'src/demos/shadertoy_player_page.dart';
import 'src/demos/live_scene_page.dart';
import 'src/demos/multi_view_page.dart';
import 'src/demos/offscreen_page.dart';
import 'src/demos/shader_toy_page.dart';
import 'src/gpu/gpu_context.dart';
import 'src/gpu/scenes.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Warm up the shared adapter/device while the gallery renders — first
  // page-open then skips the adapter request, device creation, and shader
  // compiler cold start.
  unawaited(GpuContext.obtain());
  runApp(const NitroWebgpuExampleApp());
}

class NitroWebgpuExampleApp extends StatelessWidget {
  const NitroWebgpuExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nitro_webgpu demos',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
      ),
      home: const GalleryPage(),
    );
  }
}

class _DemoEntry {
  const _DemoEntry({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final WidgetBuilder builder;
}

class GalleryPage extends StatelessWidget {
  const GalleryPage({super.key});

  static final List<_DemoEntry> _demos = [
    _DemoEntry(
      title: 'WGSL shader toy',
      subtitle: 'Live-edit WGSL with inline compile errors, speed/param '
          'controls, and the CC0 "Neon cubes" raymarcher by mrange',
      icon: Icons.auto_awesome,
      builder: (_) => const ShaderToyPage(),
    ),
    _DemoEntry(
      title: 'Shadertoy player',
      subtitle: 'Paste GLSL from shadertoy.com or WGSL snippets — mouse '
          'input, Buffer A feedback, and texture channels',
      icon: Icons.play_circle_outline,
      builder: (_) => const ShadertoyPlayerPage(),
    ),
    _DemoEntry(
      title: 'GPU particles',
      subtitle: 'A compute kernel drives 100k instanced particles that never '
          'leave the GPU — kernel is live-editable',
      icon: Icons.scatter_plot,
      builder: (_) => const ParticlesPage(),
    ),
    _DemoEntry(
      title: 'Compute shader toy',
      subtitle: 'Run Slang-playground compute kernels (imageMain → storage '
          'texture) with live editing and inline compile errors',
      icon: Icons.grain,
      builder: (_) => const ComputeToyPage(),
    ),
    _DemoEntry(
      title: 'Performance benchmark',
      subtitle: 'Four heavy scenes — raymarcher, Mandelbulb, FBM warp, '
          'metaballs — with a sequential timed run and per-scene GPU numbers',
      icon: Icons.speed,
      builder: (_) => const BenchmarkPage(),
    ),
    _DemoEntry(
      title: 'Multi render',
      subtitle: 'Four presenters rendering different scenes at once on the '
          'shared device, each with its own FPS counter',
      icon: Icons.grid_view,
      builder: (_) => const MultiViewPage(),
    ),
    _DemoEntry(
      title: 'Spinning triangle',
      subtitle: 'Uniform-driven rotation at full framerate',
      icon: Icons.change_history,
      builder: (_) => LiveScenePage(
        title: 'Spinning triangle',
        sceneBuilder: SpinningTriangleScene.new,
      ),
    ),
    _DemoEntry(
      title: 'Plasma',
      subtitle: 'Fullscreen fragment effect',
      icon: Icons.waves,
      builder: (_) => LiveScenePage(
        title: 'Plasma',
        sceneBuilder: PlasmaScene.new,
      ),
    ),
    _DemoEntry(
      title: 'Compute',
      subtitle: 'A WGSL kernel doubles 64 floats and reads them back',
      icon: Icons.memory,
      builder: (_) => const ComputePage(),
    ),
    _DemoEntry(
      title: 'Offscreen render + readback',
      subtitle: 'Render to a texture, read pixels, decode to a Flutter Image',
      icon: Icons.image,
      builder: (_) => const OffscreenPage(),
    ),
    _DemoEntry(
      title: 'Adapter probe',
      subtitle: 'Backend, adapter identity, and device limits',
      icon: Icons.info_outline,
      builder: (_) => const AdapterProbePage(),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('nitro_webgpu demos')),
      body: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _demos.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final demo = _demos[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: Icon(demo.icon),
              title: Text(demo.title),
              subtitle: Text(demo.subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: demo.builder)),
            ),
          );
        },
      ),
    );
  }
}
