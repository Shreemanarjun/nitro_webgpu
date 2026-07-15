import 'package:flutter/material.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

import '../gpu/gpu_context.dart';
import '../gpu/scenes.dart';
import 'fps_overlay.dart';

/// Renders a [GpuScene] live on the shared device, with an FPS counter
/// pinned to the top-left corner.
///
/// Owns the scene: it is disposed when the view unmounts.
class GpuSceneView extends StatefulWidget {
  const GpuSceneView({super.key, required this.scene, this.showFps = true});

  final GpuScene scene;
  final bool showFps;

  @override
  State<GpuSceneView> createState() => _GpuSceneViewState();
}

class _GpuSceneViewState extends State<GpuSceneView> {
  final FpsTracker _fps = FpsTracker();
  GpuContext? _ctx;
  String? _error;

  @override
  void initState() {
    super.initState();
    GpuContext.obtain().then((ctx) {
      if (mounted) setState(() => _ctx = ctx);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  Future<void> _onFrame(GpuRenderTarget target, Duration elapsed) async {
    await widget.scene.render(_ctx!.device, target, elapsed);
    _fps.tick();
  }

  @override
  void dispose() {
    widget.scene.dispose();
    _fps.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text('GPU unavailable: $_error'));
    }
    final ctx = _ctx;
    if (ctx == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        WebGpuView(device: ctx.device, onFrame: _onFrame),
        if (widget.showFps)
          Positioned(top: 8, left: 8, child: FpsOverlay(tracker: _fps)),
      ],
    );
  }
}
