import 'package:flutter/foundation.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

import 'scenes.dart';

/// A hot-swappable shader scene for the shader-toy demo.
///
/// [setSource] queues a new WGSL module; it is compiled on the next frame
/// through the checked create. On validation errors the previous pipeline
/// keeps rendering and the error text (with naga's line/column diagnostics)
/// is published on [compileError].
class ShaderToyScene implements GpuScene {
  ShaderToyScene({required String source}) : _pendingSource = source;

  /// Multiplies wall time; 0 freezes via [paused] instead so resume is clean.
  double timeScale = 1.0;

  /// Fed into the uniform block's `param` slot.
  double paramValue = 0.0;

  bool paused = false;

  final ValueNotifier<String?> compileError = ValueNotifier(null);

  String? _pendingSource;
  String? _activeSource;
  double _accum = 0;
  Duration? _lastElapsed;
  bool _disposed = false;

  GpuDevice? _device;
  GpuTextureFormat? _format;
  GpuShaderModule? _module;
  GpuRenderPipeline? _pipeline;
  GpuBindGroupLayout? _layout;
  GpuBindGroup? _bindGroup;
  GpuBuffer? _uniforms;

  @override
  String get name => 'shader-toy';

  /// Queues [source] for compilation on the next frame.
  void setSource(String source) => _pendingSource = source;

  Future<void> _trySwap(GpuDevice device, GpuTextureFormat format) async {
    final source = _pendingSource ?? _activeSource;
    _pendingSource = null;
    if (source == null) return;
    GpuShaderModule? module;
    GpuRenderPipeline? pipeline;
    GpuBindGroupLayout? layout;
    GpuBindGroup? bindGroup;
    try {
      module = await device.createShaderModule(source, label: name);
      pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: format,
        label: name,
      );
      layout = pipeline.getBindGroupLayout(0);
      bindGroup = device.createBindGroup(layout: layout, entries: [
        GpuBufferBinding(binding: 0, buffer: _uniforms!),
      ]);
    } catch (e) {
      bindGroup?.dispose();
      layout?.dispose();
      pipeline?.dispose();
      module?.dispose();
      if (!_disposed) {
        compileError.value = e is GpuValidationException ? e.message : '$e';
      }
      return;
    }
    if (_disposed) {
      // The scene was torn down while compiling — drop the new pipeline.
      bindGroup.dispose();
      layout.dispose();
      pipeline.dispose();
      module.dispose();
      return;
    }
    // Success — swap out the old pipeline.
    _disposePipeline();
    _module = module;
    _pipeline = pipeline;
    _layout = layout;
    _bindGroup = bindGroup;
    _activeSource = source;
    _device = device;
    _format = format;
    compileError.value = null;
  }

  @override
  Future<void> render(GpuDevice device, GpuRenderTarget target,
      Duration elapsed, {GpuTimestampWrites? timestamps}) async {
    if (_disposed) return;
    final last = _lastElapsed ?? elapsed;
    _lastElapsed = elapsed;
    if (!paused) {
      _accum += (elapsed - last).inMicroseconds / 1e6 * timeScale;
    }

    _uniforms ??= device.createBuffer(
      size: 16,
      usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst,
      label: '$name-uniforms',
    );
    if (_pendingSource != null ||
        _format != target.targetFormat ||
        _device != device) {
      await _trySwap(device, target.targetFormat);
    }
    final pipeline = _pipeline;
    final bindGroup = _bindGroup;
    if (pipeline == null || bindGroup == null) {
      // Nothing compiled yet: still clear the target. Presenting an
      // unrendered ring slot would flash content from several frames ago.
      final encoder = device.createCommandEncoder(label: '$name-clear');
      encoder
          .beginRenderPass(colorAttachments: [
            GpuColorAttachmentInfo(view: target.view, clearColor: GpuColor.black),
          ])
          .end();
      device.queue.submit([encoder.finish()]);
      return;
    }

    device.queue.writeBuffer(
      _uniforms!,
      Float32List.fromList([
        _accum,
        target.width.toDouble(),
        target.height.toDouble(),
        paramValue,
      ]).buffer.asUint8List(),
    );
    final encoder = device.createCommandEncoder(label: name);
    final pass = encoder.beginRenderPass(colorAttachments: [
      GpuColorAttachmentInfo(view: target.view, clearColor: GpuColor.black),
    ], timestampWrites: timestamps);
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.draw(3);
    pass.end();
    device.queue.submit([encoder.finish()]);
  }

  void _disposePipeline() {
    _bindGroup?.dispose();
    _layout?.dispose();
    _pipeline?.dispose();
    _module?.dispose();
    _bindGroup = null;
    _layout = null;
    _pipeline = null;
    _module = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _disposePipeline();
    _uniforms?.dispose();
    _uniforms = null;
    compileError.dispose();
  }
}
