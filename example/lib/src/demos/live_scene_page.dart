import 'package:flutter/material.dart';

import '../gpu/scenes.dart';
import '../widgets/gpu_scene_view.dart';

/// Fullscreen live render of one scene with the FPS counter top-left.
class LiveScenePage extends StatelessWidget {
  const LiveScenePage({
    super.key,
    required this.title,
    required this.sceneBuilder,
  });

  final String title;
  final GpuScene Function() sceneBuilder;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: GpuSceneView(
        scene: sceneBuilder(),
        dynamicResolution: true,
      ),
    );
  }
}
