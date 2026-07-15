import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

import '../gpu/gpu_context.dart';

/// Renders a triangle into an offscreen texture, reads the pixels back, and
/// shows them as a Flutter [Image] — proving the readback path end-to-end.
class OffscreenPage extends StatefulWidget {
  const OffscreenPage({super.key});

  @override
  State<OffscreenPage> createState() => _OffscreenPageState();
}

class _OffscreenPageState extends State<OffscreenPage> {
  static const int _size = 256;
  ui.Image? _image;
  String? _status;

  static const _wgsl = '''
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  var pos = array<vec2<f32>, 3>(
    vec2(0.0, 0.8), vec2(-0.8, -0.8), vec2(0.8, -0.8));
  return vec4(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
  let uv = frag.xy / 256.0;
  return vec4(uv.x, 0.9 - uv.y * 0.5, 0.6, 1.0);
}
''';

  @override
  void initState() {
    super.initState();
    _render();
  }

  Future<void> _render() async {
    GpuTexture? texture;
    GpuTextureView? view;
    GpuBuffer? readback;
    GpuShaderModule? module;
    GpuRenderPipeline? pipeline;
    try {
      final device = (await GpuContext.obtain()).device;
      module = await device.createShaderModule(_wgsl);
      pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
      );
      texture = device.createTexture(
        width: _size,
        height: _size,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      view = texture.createView();
      readback = device.createBuffer(
        size: _size * _size * 4,
        usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst,
      );

      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(
          view: view,
          clearColor: const GpuColor(0.10, 0.10, 0.14),
        ),
      ]);
      pass.setPipeline(pipeline);
      pass.draw(3);
      pass.end();
      encoder.copyTextureToBuffer(texture, readback);
      device.queue.submit([encoder.finish()]);
      final pixels = await readback.mapRead();

      final image = await _rgbaToImage(pixels, _size, _size);
      setState(() {
        _image = image;
        _status = 'Rendered offscreen at $_size×$_size, read back '
            '${pixels.length ~/ 1024} KiB, decoded into a Flutter Image.';
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      readback?.dispose();
      view?.dispose();
      texture?.dispose();
      pipeline?.dispose();
      module?.dispose();
    }
  }

  static Future<ui.Image> _rgbaToImage(Uint8List rgba, int w, int h) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: w,
      height: h,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offscreen render + readback')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_image != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: RawImage(
                  image: _image,
                  width: 256,
                  height: 256,
                  filterQuality: FilterQuality.none,
                ),
              )
            else
              const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_status ?? 'rendering…', textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}
