import 'package:flutter/material.dart';

import '../gpu/shadertoy_engine.dart';
import '../widgets/gpu_scene_view.dart';
import 'showcases.dart';

/// Gallery of real-world shader techniques, grouped by category. Every card
/// opens a fullscreen live viewer; interactive ones respond to touch.
class ShowcaseGalleryPage extends StatelessWidget {
  const ShowcaseGalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final categories = <String, List<Showcase>>{};
    for (final s in showcases) {
      categories.putIfAbsent(s.category, () => []).add(s);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Shader showcase')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final entry in categories.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
              child: Text(entry.key,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final showcase in entry.value)
              Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  title: Text(showcase.title),
                  subtitle: Text(showcase.description),
                  trailing: showcase.interactive
                      ? const Icon(Icons.touch_app, size: 18)
                      : const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ShowcaseViewerPage(showcase: showcase),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Fullscreen live viewer for one showcase.
class ShowcaseViewerPage extends StatefulWidget {
  const ShowcaseViewerPage({super.key, required this.showcase});

  final Showcase showcase;

  @override
  State<ShowcaseViewerPage> createState() => _ShowcaseViewerPageState();
}

class _ShowcaseViewerPageState extends State<ShowcaseViewerPage> {
  late final scene = widget.showcase.build();

  @override
  void dispose() {
    scene.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: separate variable — a closure capturing the reassigned `view`
    // would reference itself and stack-overflow on first build.
    final inner = GpuSceneView(
      scene: scene,
      ownsScene: false,
      dynamicResolution: true,
    );
    Widget view = inner;
    final engine = scene;
    if (widget.showcase.interactive && engine is ShadertoyEngine) {
      view = LayoutBuilder(builder: (context, box) {
        return GestureDetector(
          onPanDown: (d) => engine.setMouseNormalized(
              d.localPosition.dx / box.maxWidth,
              d.localPosition.dy / box.maxHeight,
              press: true),
          onPanUpdate: (d) => engine.setMouseNormalized(
              d.localPosition.dx / box.maxWidth,
              d.localPosition.dy / box.maxHeight),
          child: inner,
        );
      });
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.showcase.title),
        actions: [
          if (widget.showcase.interactive)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Icon(Icons.touch_app, size: 18),
            ),
        ],
      ),
      body: view,
    );
  }
}
