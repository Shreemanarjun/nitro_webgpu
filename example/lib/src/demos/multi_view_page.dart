import 'package:flutter/material.dart';

import '../gpu/scenes.dart';
import '../widgets/gpu_scene_view.dart';

/// Four independent presenters rendering different scenes simultaneously on
/// the one shared device — each tile has its own swap target, frame loop,
/// and FPS counter.
class MultiViewPage extends StatelessWidget {
  const MultiViewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tiles = <(String, GpuScene)>[
      ('Triangle', SpinningTriangleScene()),
      ('Plasma', PlasmaScene()),
      ('Rings', RingsScene()),
      ('Bars', BarsScene()),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Multi render — 4 presenters')),
      body: Padding(
        padding: const EdgeInsets.all(8),
        child: GridView.count(
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            for (final (label, scene) in tiles)
              Card(
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    GpuSceneView(
                      scene: scene,
                      detailedPerf: false,
                      dynamicResolution: true,
                    ),
                    Positioned(
                      bottom: 6,
                      right: 10,
                      child: Text(
                        label,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
