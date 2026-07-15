import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';
import 'package:nitro_webgpu/src/nitro_webgpu_present.native.dart';
import 'package:nitro_webgpu_example/src/gpu/shader_presets.dart';

// CI runners have no real GPU; --dart-define=WGPU_FORCE_FALLBACK=true selects
// a software adapter (lavapipe / WARP).
const bool kForceFallback = bool.fromEnvironment('WGPU_FORCE_FALLBACK');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('M0 link proof', () {
    test('wgpuVersion returns the pinned wgpu-native version', () {
      expect(Gpu.version, '29.0.1.1');
    });

    test('ensureInitialized is idempotent', () {
      Gpu.ensureInitialized();
      Gpu.ensureInitialized();
    });
  });

  group('M1a adapter/device', () {
    test('requestAdapter resolves with real adapter info', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final info = adapter.info;
      expect(info.device, isNotEmpty);
      expect(adapter.backendType, isNot(GpuBackendType.undefined));
      expect(adapter.adapterType, isA<GpuAdapterType>());

      final limits = adapter.limits;
      expect(limits.maxTextureDimension2D, greaterThanOrEqualTo(2048));
      expect(limits.maxBufferSize, greaterThan(0));
      adapter.dispose();
    });

    test('requestDevice resolves and provides a queue', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice(label: 'test-device');
      expect(device.queue, isNotNull);
      device.dispose();
      adapter.dispose();
    });

    test('adapter use after dispose throws StateError', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      adapter.dispose();
      adapter.dispose(); // double dispose is a no-op
      expect(() => adapter.info, throwsStateError);
      expect(() => adapter.requestDevice(), throwsStateError);
    });
  });

  group('M1a error handling', () {
    test('clean error scope pops null', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      device.pushErrorScope(GpuErrorFilter.validation);
      final error = await device.popErrorScope();
      expect(error, isNull);
      device.dispose();
      adapter.dispose();
    });

    test('popErrorScope on empty stack rejects', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      await expectLater(device.popErrorScope(), throwsA(anything));
      device.dispose();
      adapter.dispose();
    });

    test('device.destroy() then dispose() is safe', () async {
      // UPSTREAM GAP (wgpu-native v29.0.1.1, verified with a standalone C
      // probe): the deviceLostCallbackInfo callback is never invoked — not on
      // wgpuDeviceDestroy, not on wgpuDeviceRelease (gfx-rs/wgpu#5132 family).
      // The onLost stream stays in the API; assert the teardown sequence is
      // safe and revisit event delivery on the next wgpu-native bump.
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final sub = device.onLost.listen((_) {});
      device.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      device.dispose();
      await sub.cancel();
      adapter.dispose();
    });
  });

  group('M1b buffers + compute', () {
    const doubleWgsl = '''
@group(0) @binding(0) var<storage, read_write> data: array<f32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  data[gid.x] = data[gid.x] * 2.0;
}
''';

    test('canonical: compute kernel doubles a 64-float buffer', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice(label: 'compute-device');
      final queue = device.queue;

      final storage = device.createBuffer(
        size: 64 * 4,
        usage: GpuBufferUsage.storage |
            GpuBufferUsage.copyDst |
            GpuBufferUsage.copySrc,
        label: 'storage',
      );
      final staging = device.createBuffer(
        size: 64 * 4,
        usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst,
        label: 'staging',
      );

      final input = Float32List.fromList(
          List.generate(64, (i) => (i + 1).toDouble()));
      queue.writeBuffer(storage, input.buffer.asUint8List());

      final module = await device.createShaderModule(doubleWgsl);
      final pipeline = await device.createComputePipeline(module: module);
      final layout = pipeline.getBindGroupLayout(0);
      final bindGroup = device.createBindGroup(layout: layout, entries: [
        GpuBufferBinding(binding: 0, buffer: storage),
      ]);

      final encoder = device.createCommandEncoder();
      final pass = encoder.beginComputePass();
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);
      pass.dispatchWorkgroups(1);
      pass.end();
      encoder.copyBufferToBuffer(storage, staging);
      queue.submit([encoder.finish()]);
      await queue.onSubmittedWorkDone();

      final bytes = await staging.mapRead();
      final result = bytes.buffer.asFloat32List(bytes.offsetInBytes, 64);
      for (var i = 0; i < 64; i++) {
        expect(result[i], 2.0 * (i + 1),
            reason: 'element $i should be doubled');
      }

      bindGroup.dispose();
      layout.dispose();
      pipeline.dispose();
      module.dispose();
      staging.dispose();
      storage.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('invalid WGSL throws GpuValidationException', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      await expectLater(
        device.createShaderModule('fn broken( {'),
        throwsA(isA<GpuValidationException>()),
      );
      device.dispose();
      adapter.dispose();
    });

    test('invalid entry point throws GpuValidationException', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final module = await device.createShaderModule(doubleWgsl);
      await expectLater(
        device.createComputePipeline(module: module, entryPoint: 'nonexistent'),
        throwsA(isA<GpuValidationException>()),
      );
      module.dispose();
      device.dispose();
      adapter.dispose();
    });
  });

  group('M1c offscreen render + readback', () {
    // 64×4 = 256 bytes/row — exactly meets WebGPU's 256-byte row alignment.
    const w = 64, h = 64;

    test('clear-to-red renders [255,0,0,255] everywhere', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final queue = device.queue;

      final texture = device.createTexture(
        width: w,
        height: h,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final view = texture.createView();
      final readback = device.createBuffer(
        size: w * h * 4,
        usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst,
      );

      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(
          view: view,
          clearColor: const GpuColor(1, 0, 0),
        ),
      ]);
      pass.end(); // clear-only pass
      encoder.copyTextureToBuffer(texture, readback);
      queue.submit([encoder.finish()]);

      final pixels = await readback.mapRead();
      expect(pixels.length, w * h * 4);
      for (var i = 0; i < pixels.length; i += 4) {
        expect(pixels[i], 255, reason: 'red at byte $i');
        expect(pixels[i + 1], 0, reason: 'green at byte $i');
        expect(pixels[i + 2], 0, reason: 'blue at byte $i');
        expect(pixels[i + 3], 255, reason: 'alpha at byte $i');
      }

      readback.dispose();
      view.dispose();
      texture.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('fullscreen triangle draws green center pixel', () async {
      const wgsl = '''
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  var pos = array<vec2<f32>, 3>(
    vec2(-1.0, -3.0), vec2(3.0, 1.0), vec2(-1.0, 1.0));
  return vec4(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4<f32> {
  return vec4(0.0, 1.0, 0.0, 1.0);
}
''';
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final queue = device.queue;

      final module = await device.createShaderModule(wgsl);
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
      );

      final texture = device.createTexture(
        width: w,
        height: h,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final view = texture.createView();
      final readback = device.createBuffer(
        size: w * h * 4,
        usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst,
      );

      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(view: view),
      ]);
      pass.setPipeline(pipeline);
      pass.draw(3);
      pass.end();
      encoder.copyTextureToBuffer(texture, readback);
      queue.submit([encoder.finish()]);

      final pixels = await readback.mapRead();
      final center = ((h ~/ 2) * w + (w ~/ 2)) * 4;
      expect(pixels[center], 0);
      expect(pixels[center + 1], 255);
      expect(pixels[center + 2], 0);
      expect(pixels[center + 3], 255);

      readback.dispose();
      view.dispose();
      texture.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });
  });

  group('M2.1 presentation path', () {
    test('macOS presenter uses the Metal blit path (not CPU readback)',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final token = NitroWebgpuPresent.instance
          .createPresenter(device.debugAddress, 64, 64);
      expect(token, isNonZero);
      expect(NitroWebgpuPresent.instance.presenterUsesGpuPath(token), isTrue,
          reason: 'macOS runs on Metal — the GPU blit path must be active');
      await NitroWebgpuPresent.instance.destroyPresenter(token);
      device.dispose();
      adapter.dispose();
    });
  });

  group('M2.0 WebGpuView', () {
    testWidgets('pumps live frames through the presenter', (tester) async {
      final binding = tester.binding as LiveTestWidgetsFlutterBinding;
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final module = await device.createShaderModule('''
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  var pos = array<vec2<f32>, 3>(
    vec2(0.0, 0.7), vec2(-0.7, -0.7), vec2(0.7, -0.7));
  return vec4(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4<f32> {
  return vec4(0.0, 1.0, 0.0, 1.0);
}
''');

      GpuRenderPipeline? pipeline;
      var frames = 0;
      Future<void> onFrame(GpuRenderTarget target, Duration elapsed) async {
        pipeline ??= await device.createRenderPipeline(
          module: module,
          targetFormat: target.targetFormat,
        );
        final encoder = device.createCommandEncoder();
        final pass = encoder.beginRenderPass(colorAttachments: [
          GpuColorAttachmentInfo(view: target.view),
        ]);
        pass.setPipeline(pipeline!);
        pass.draw(3);
        pass.end();
        device.queue.submit([encoder.finish()]);
        frames++;
      }

      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 256,
            height: 256,
            child: WebGpuView(device: device, onFrame: onFrame),
          ),
        ),
      ));

      // Let the live ticker run for real time.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pump();
      expect(frames, greaterThan(5),
          reason: 'presenter should pump multiple live frames');

      // Unmount → WebGpuView drains and destroys its presenter.
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)));

      pipeline?.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });
  });

  group('example shader presets', () {
    test('every preset compiles and builds a render pipeline', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      for (final preset in shaderPresets) {
        final module = await device.createShaderModule(preset.source,
            label: preset.name);
        final pipeline = await device.createRenderPipeline(
          module: module,
          targetFormat: GpuTextureFormat.bgra8Unorm,
          label: preset.name,
        );
        pipeline.dispose();
        module.dispose();
      }
      device.dispose();
      adapter.dispose();
    });
  });

  group('M1a lifecycle stress', () {
    test('repeated adapter/device create+dispose stays stable', () async {
      for (var i = 0; i < 25; i++) {
        final adapter =
            await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
        final device = await adapter.requestDevice();
        device.queue; // touch the queue so it is created and released too
        device.dispose();
        adapter.dispose();
      }
    });
  });
}
