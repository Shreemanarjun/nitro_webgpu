import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';
import 'package:nitro_webgpu/src/nitro_webgpu_present.native.dart';
import 'package:nitro_webgpu_example/src/demos/shader_toy_page.dart';
import 'package:nitro_webgpu_example/src/gpu/benchmark_scenes.dart';
import 'package:nitro_webgpu_example/src/gpu/scenes.dart';
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

  group('M2.1 presenter ring', () {
    test('acquire hands out distinct slots and the ring recovers', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final token = NitroWebgpuPresent.instance
          .createPresenter(device.debugAddress, 64, 64);
      expect(token, isNonZero);

      // Round-robin: two back-to-back acquires must hand out different
      // render targets — this is what lets frame N+1 overlap frame N.
      final a1 = await NitroWebgpuPresent.instance.acquireFrame(token);
      expect(a1, isNonZero);
      NitroWebgpuPresent.instance.presentFrame(token);
      final a2 = await NitroWebgpuPresent.instance.acquireFrame(token);
      expect(a2, isNonZero);
      expect(a2, isNot(a1), reason: 'second acquire must use another slot');
      NitroWebgpuPresent.instance.presentFrame(token);

      // Hammer the ring: with the 2-in-flight backpressure cap this must
      // never crash, and acquires either succeed or drop cleanly (0).
      var drops = 0;
      for (var i = 0; i < 50; i++) {
        final v = await NitroWebgpuPresent.instance.acquireFrame(token);
        if (v == 0) {
          drops++;
        } else {
          NitroWebgpuPresent.instance.presentFrame(token);
        }
      }
      // After draining, the ring must recover and hand out slots again.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final recovered =
          await NitroWebgpuPresent.instance.acquireFrame(token);
      expect(recovered, isNonZero,
          reason: 'ring must recover after in-flight presents drain '
              '($drops drops during hammering is fine)');
      NitroWebgpuPresent.instance.presentFrame(token);

      // Destroy with work potentially still in flight — must drain safely.
      await NitroWebgpuPresent.instance.destroyPresenter(token);
      device.dispose();
      adapter.dispose();
    });

    testWidgets('pipelined presenter sustains cheap-scene throughput',
        (tester) async {
      final binding = tester.binding as LiveTestWidgetsFlutterBinding;
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      // Only assert a throughput floor on the GPU blit path — readback
      // fallbacks (CI software adapters) are legitimately slower.
      final probeToken = NitroWebgpuPresent.instance
          .createPresenter(device.debugAddress, 8, 8);
      final gpuPath =
          NitroWebgpuPresent.instance.presenterUsesGpuPath(probeToken);
      await NitroWebgpuPresent.instance.destroyPresenter(probeToken);

      var frames = 0;
      Future<void> onFrame(GpuRenderTarget target, Duration elapsed) async {
        final encoder = device.createCommandEncoder();
        final pass = encoder.beginRenderPass(colorAttachments: [
          GpuColorAttachmentInfo(view: target.view),
        ]);
        pass.end(); // clear-only: trivially cheap
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
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pump();

      if (gpuPath) {
        expect(frames, greaterThan(60),
            reason: 'a clear-only scene on the Metal blit path must sustain '
                'well over 30 fps (pipelined ring)');
      } else {
        expect(frames, greaterThan(5),
            reason: 'readback fallback still pumps frames');
      }

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)));
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

  group('textures + samplers', () {
    test('uploaded texture samples back exactly through a render pass',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final queue = device.queue;

      // 2×2 source texture with four distinct texels.
      final source = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
        label: 'source',
      );
      final pixels = Uint8List.fromList([
        255, 0, 0, 255, /*   */ 0, 255, 0, 255, // row 0: red, green
        0, 0, 255, 255, /*   */ 255, 255, 255, 255, // row 1: blue, white
      ]);
      queue.writeTexture(source, pixels);

      final sampler = device.createSampler(
        magFilter: GpuFilterMode.nearest,
        minFilter: GpuFilterMode.nearest,
      );
      final sourceView = source.createView();

      final module = await device.createShaderModule('''
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
  return textureSample(tex, samp, frag.xy / 2.0);
}
''');
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
      );
      final layout = pipeline.getBindGroupLayout(0);
      final bindGroup = device.createBindGroup(layout: layout, entries: [
        GpuSamplerBinding(binding: 0, sampler: sampler),
        GpuTextureBinding(binding: 1, view: sourceView),
      ]);

      // Render the sampled texture 1:1 into a 2×2 target and read it back
      // (256-byte row alignment applies to the readback copy).
      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
        label: 'target',
      );
      final targetView = target.createView();
      final readback = device.createBuffer(
        size: 256 * 2,
        usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst,
      );

      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(view: targetView),
      ]);
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);
      pass.draw(3);
      pass.end();
      encoder.copyTextureToBuffer(target, readback, bytesPerRow: 256);
      queue.submit([encoder.finish()]);

      final bytes = await readback.mapRead();
      List<int> texel(int x, int y) =>
          bytes.sublist(y * 256 + x * 4, y * 256 + x * 4 + 4);
      expect(texel(0, 0), [255, 0, 0, 255], reason: 'top-left red');
      expect(texel(1, 0), [0, 255, 0, 255], reason: 'top-right green');
      expect(texel(0, 1), [0, 0, 255, 255], reason: 'bottom-left blue');
      expect(texel(1, 1), [255, 255, 255, 255], reason: 'bottom-right white');

      readback.dispose();
      targetView.dispose();
      target.dispose();
      bindGroup.dispose();
      layout.dispose();
      pipeline.dispose();
      module.dispose();
      sourceView.dispose();
      sampler.dispose();
      source.dispose();
      device.dispose();
      adapter.dispose();
    });
  });

  group('3D rendering', () {
    Future<Uint8List> renderAndRead(
      GpuDevice device,
      void Function(GpuCommandEncoder encoder, GpuTextureView color,
              GpuTextureView? depth)
          record, {
      bool withDepth = false,
    }) async {
      final color = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final colorView = color.createView();
      GpuTexture? depth;
      GpuTextureView? depthView;
      if (withDepth) {
        depth = device.createTexture(
          width: 2,
          height: 2,
          format: GpuTextureFormat.depth24Plus,
          usage: GpuTextureUsage.renderAttachment,
        );
        depthView = depth.createView();
      }
      final readback = device.createBuffer(
        size: 256 * 2,
        usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst,
      );
      final encoder = device.createCommandEncoder();
      record(encoder, colorView, depthView);
      encoder.copyTextureToBuffer(color, readback, bytesPerRow: 256);
      device.queue.submit([encoder.finish()]);
      final bytes = await readback.mapRead();
      readback.dispose();
      depthView?.dispose();
      depth?.dispose();
      colorView.dispose();
      color.dispose();
      return bytes;
    }

    List<int> texel(Uint8List bytes, int x, int y) =>
        bytes.sublist(y * 256 + x * 4, y * 256 + x * 4 + 4);

    test('vertex + index buffers drive an indexed quad', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final module = await device.createShaderModule('''
struct VOut { @builtin(position) pos: vec4f, @location(0) color: vec4f };
@vertex
fn vs_main(@location(0) pos: vec2f, @location(1) color: vec4f) -> VOut {
  var o: VOut;
  o.pos = vec4f(pos, 0.0, 1.0);
  o.color = color;
  return o;
}
@fragment
fn fs_main(v: VOut) -> @location(0) vec4f { return v.color; }
''');
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        vertexBuffers: [
          GpuVertexLayout(arrayStride: 24, attributes: const [
            GpuVertexAttr(
                format: GpuVertexFormat.float32x2,
                offset: 0,
                shaderLocation: 0),
            GpuVertexAttr(
                format: GpuVertexFormat.float32x4,
                offset: 8,
                shaderLocation: 1),
          ]),
        ],
      );

      // Fullscreen green quad: 4 vertices, 6 indices (uint16).
      final vertices = Float32List.fromList([
        -1, -1, 0, 1, 0, 1, //
        1, -1, 0, 1, 0, 1, //
        -1, 1, 0, 1, 0, 1, //
        1, 1, 0, 1, 0, 1, //
      ]);
      final indices = Uint16List.fromList([0, 1, 2, 2, 1, 3]);
      final vbuf = device.createBuffer(
        size: vertices.lengthInBytes,
        usage: GpuBufferUsage.vertex | GpuBufferUsage.copyDst,
      );
      final ibuf = device.createBuffer(
        size: 16, // 12 bytes of indices, padded to 4-byte multiple
        usage: GpuBufferUsage.index | GpuBufferUsage.copyDst,
      );
      device.queue.writeBuffer(vbuf, vertices.buffer.asUint8List());
      device.queue.writeBuffer(ibuf, indices.buffer.asUint8List());

      final bytes = await renderAndRead(device, (encoder, color, _) {
        final pass = encoder.beginRenderPass(colorAttachments: [
          GpuColorAttachmentInfo(view: color),
        ]);
        pass.setPipeline(pipeline);
        pass.setVertexBuffer(0, vbuf);
        pass.setIndexBuffer(ibuf, GpuIndexFormat.uint16);
        pass.drawIndexed(6);
        pass.end();
      });
      for (final p in [texel(bytes, 0, 0), texel(bytes, 1, 1)]) {
        expect(p, [0, 255, 0, 255], reason: 'indexed quad fills the target');
      }

      ibuf.dispose();
      vbuf.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('depth testing rejects farther fragments drawn later', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final module = await device.createShaderModule('''
struct VOut { @builtin(position) pos: vec4f, @location(0) color: vec4f };
@vertex
fn vs_main(@location(0) pos: vec3f, @location(1) color: vec4f) -> VOut {
  var o: VOut;
  o.pos = vec4f(pos, 1.0);
  o.color = color;
  return o;
}
@fragment
fn fs_main(v: VOut) -> @location(0) vec4f { return v.color; }
''');
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        depthFormat: GpuTextureFormat.depth24Plus,
        vertexBuffers: [
          GpuVertexLayout(arrayStride: 28, attributes: const [
            GpuVertexAttr(
                format: GpuVertexFormat.float32x3,
                offset: 0,
                shaderLocation: 0),
            GpuVertexAttr(
                format: GpuVertexFormat.float32x4,
                offset: 12,
                shaderLocation: 1),
          ]),
        ],
      );

      // NEAR blue quad over the left half (z=0.2) drawn FIRST, then a FAR
      // red fullscreen quad (z=0.8): with depth testing the red quad must
      // lose on the left half despite being drawn later.
      final vertices = Float32List.fromList([
        // blue left-half quad, z = 0.2
        -1, -1, 0.2, 0, 0, 1, 1, //
        0, -1, 0.2, 0, 0, 1, 1, //
        -1, 1, 0.2, 0, 0, 1, 1, //
        0, 1, 0.2, 0, 0, 1, 1, //
        // red fullscreen quad, z = 0.8
        -1, -1, 0.8, 1, 0, 0, 1, //
        1, -1, 0.8, 1, 0, 0, 1, //
        -1, 1, 0.8, 1, 0, 0, 1, //
        1, 1, 0.8, 1, 0, 0, 1, //
      ]);
      final indices =
          Uint16List.fromList([0, 1, 2, 2, 1, 3, 4, 5, 6, 6, 5, 7]);
      final vbuf = device.createBuffer(
        size: vertices.lengthInBytes,
        usage: GpuBufferUsage.vertex | GpuBufferUsage.copyDst,
      );
      final ibuf = device.createBuffer(
        size: indices.lengthInBytes,
        usage: GpuBufferUsage.index | GpuBufferUsage.copyDst,
      );
      device.queue.writeBuffer(vbuf, vertices.buffer.asUint8List());
      device.queue.writeBuffer(ibuf, indices.buffer.asUint8List());

      final bytes = await renderAndRead(device, withDepth: true,
          (encoder, color, depth) {
        final pass = encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: color)],
          depthAttachment: GpuDepthAttachmentInfo(view: depth!),
        );
        pass.setPipeline(pipeline);
        pass.setVertexBuffer(0, vbuf);
        pass.setIndexBuffer(ibuf, GpuIndexFormat.uint16);
        pass.drawIndexed(12);
        pass.end();
      });
      expect(texel(bytes, 0, 0), [0, 0, 255, 255],
          reason: 'near blue quad must survive on the left');
      expect(texel(bytes, 1, 0), [255, 0, 0, 255],
          reason: 'far red quad fills the right');

      ibuf.dispose();
      vbuf.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('alpha blending mixes source over destination', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final module = await device.createShaderModule('''
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(0.0, 1.0, 0.0, 0.5); }
''');
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        blend: GpuBlendMode.alpha,
      );

      final bytes = await renderAndRead(device, (encoder, color, _) {
        final pass = encoder.beginRenderPass(colorAttachments: [
          GpuColorAttachmentInfo(
              view: color, clearColor: const GpuColor(1, 0, 0)),
        ]);
        pass.setPipeline(pipeline);
        pass.draw(3);
        pass.end();
      });
      // 50% green over red: ~[128, 128, 0].
      final p = texel(bytes, 0, 0);
      expect(p[0], inInclusiveRange(120, 135), reason: 'red halved');
      expect(p[1], inInclusiveRange(120, 135), reason: 'green halved');
      expect(p[2], 0);

      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('explicit bind group layout drives a uniform tint', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final bgl = device.createBindGroupLayout(entries: const [
        GpuLayoutEntry(
          binding: 0,
          visibility: GpuShaderStage.fragment,
          type: GpuBindingType.uniformBuffer,
        ),
      ]);
      final pipelineLayout = device.createPipelineLayout(layouts: [bgl]);

      final module = await device.createShaderModule('''
@group(0) @binding(0) var<uniform> tint: vec4f;
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4f { return tint; }
''');
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        layout: pipelineLayout,
      );

      final uniforms = device.createBuffer(
        size: 16,
        usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst,
      );
      device.queue.writeBuffer(
          uniforms, Float32List.fromList([1, 0, 1, 1]).buffer.asUint8List());
      final bindGroup = device.createBindGroup(layout: bgl, entries: [
        GpuBufferBinding(binding: 0, buffer: uniforms),
      ]);

      final bytes = await renderAndRead(device, (encoder, color, _) {
        final pass = encoder.beginRenderPass(colorAttachments: [
          GpuColorAttachmentInfo(view: color),
        ]);
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bindGroup);
        pass.draw(3);
        pass.end();
      });
      expect(texel(bytes, 1, 1), [255, 0, 255, 255],
          reason: 'uniform magenta through an explicit layout');

      bindGroup.dispose();
      uniforms.dispose();
      pipeline.dispose();
      module.dispose();
      pipelineLayout.dispose();
      bgl.dispose();
      device.dispose();
      adapter.dispose();
    });
  });

  group('WebGPU parity batch', () {
    const fullscreenVs = '''
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}
''';

    test('scissor rect clips rendering', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final module = await device.createShaderModule('''
$fullscreenVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(0.0, 1.0, 0.0, 1.0); }
''');
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);

      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final view = target.createView();
      final readback = device.createBuffer(
          size: 512,
          usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(
            view: view, clearColor: const GpuColor(1, 0, 0)),
      ]);
      pass.setPipeline(pipeline);
      pass.setScissorRect(0, 0, 1, 2); // left column only
      pass.draw(3);
      pass.end();
      encoder.copyTextureToBuffer(target, readback, bytesPerRow: 256);
      device.queue.submit([encoder.finish()]);
      final bytes = await readback.mapRead();
      expect(bytes.sublist(0, 4), [0, 255, 0, 255], reason: 'left drawn');
      expect(bytes.sublist(4, 8), [255, 0, 0, 255],
          reason: 'right clipped by scissor');

      readback.dispose();
      view.dispose();
      target.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('buffer→texture and texture→texture copies round-trip', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      // Stage 2×2 pixels in a buffer (256-byte rows for buffer↔texture).
      final staged = Uint8List(512);
      final pix = [
        [10, 20, 30, 255],
        [40, 50, 60, 255],
        [70, 80, 90, 255],
        [100, 110, 120, 255],
      ];
      staged.setRange(0, 4, pix[0]);
      staged.setRange(4, 8, pix[1]);
      staged.setRange(256, 260, pix[2]);
      staged.setRange(260, 264, pix[3]);
      final upload = device.createBuffer(
          size: 512,
          usage: GpuBufferUsage.copySrc | GpuBufferUsage.copyDst);
      device.queue.writeBuffer(upload, staged);

      final texA = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.copyDst | GpuTextureUsage.copySrc,
      );
      final texB = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.copyDst | GpuTextureUsage.copySrc,
      );
      final readback = device.createBuffer(
          size: 512,
          usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);

      final encoder = device.createCommandEncoder();
      encoder.copyBufferToTexture(upload, texA, bytesPerRow: 256);
      encoder.copyTextureToTexture(texA, texB);
      encoder.copyTextureToBuffer(texB, readback, bytesPerRow: 256);
      device.queue.submit([encoder.finish()]);

      final bytes = await readback.mapRead();
      expect(bytes.sublist(0, 4), pix[0]);
      expect(bytes.sublist(4, 8), pix[1]);
      expect(bytes.sublist(256, 260), pix[2]);
      expect(bytes.sublist(260, 264), pix[3]);

      readback.dispose();
      texB.dispose();
      texA.dispose();
      upload.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('drawIndirect executes draw args from a buffer', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final module = await device.createShaderModule('''
$fullscreenVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(0.0, 0.0, 1.0, 1.0); }
''');
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);

      final indirect = device.createBuffer(
        size: 16,
        usage: GpuBufferUsage.indirect | GpuBufferUsage.copyDst,
      );
      device.queue.writeBuffer(
          indirect, Uint32List.fromList([3, 1, 0, 0]).buffer.asUint8List());

      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final view = target.createView();
      final readback = device.createBuffer(
          size: 512,
          usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(view: view),
      ]);
      pass.setPipeline(pipeline);
      pass.drawIndirect(indirect);
      pass.end();
      encoder.copyTextureToBuffer(target, readback, bytesPerRow: 256);
      device.queue.submit([encoder.finish()]);
      final bytes = await readback.mapRead();
      expect(bytes.sublist(0, 4), [0, 0, 255, 255]);

      readback.dispose();
      view.dispose();
      target.dispose();
      indirect.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('4x MSAA renders through a resolve target', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final module = await device.createShaderModule('''
$fullscreenVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 1.0, 0.0, 1.0); }
''');
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        sampleCount: 4,
      );

      final msaa = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment,
        sampleCount: 4,
      );
      final resolve = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final msaaView = msaa.createView();
      final resolveView = resolve.createView();
      final readback = device.createBuffer(
          size: 512,
          usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(
          view: msaaView,
          resolveTarget: resolveView,
          storeOp: GpuStoreOp.discard,
        ),
      ]);
      pass.setPipeline(pipeline);
      pass.draw(3);
      pass.end();
      encoder.copyTextureToBuffer(resolve, readback, bytesPerRow: 256);
      device.queue.submit([encoder.finish()]);
      final bytes = await readback.mapRead();
      expect(bytes.sublist(0, 4), [255, 255, 0, 255],
          reason: 'fully covered pixel resolves to pure color');

      readback.dispose();
      resolveView.dispose();
      msaaView.dispose();
      resolve.dispose();
      msaa.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('compute writes a storage texture via explicit layout', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final bgl = device.createBindGroupLayout(entries: const [
        GpuLayoutEntry(
          binding: 0,
          visibility: GpuShaderStage.compute,
          type: GpuBindingType.storageTexture,
        ),
      ]);
      final layout = device.createPipelineLayout(layouts: [bgl]);
      final module = await device.createShaderModule('''
@group(0) @binding(0) var img: texture_storage_2d<rgba8unorm, write>;
@compute @workgroup_size(2, 2)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let v = f32(gid.x + gid.y * 2u) / 4.0;
  textureStore(img, vec2<i32>(gid.xy), vec4f(v, 1.0 - v, 0.5, 1.0));
}
''');
      final pipeline = await device.createComputePipeline(
          module: module, layout: layout);

      final tex = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.storageBinding | GpuTextureUsage.copySrc,
      );
      final view = tex.createView();
      final bindGroup = device.createBindGroup(layout: bgl, entries: [
        GpuTextureBinding(binding: 0, view: view),
      ]);
      final readback = device.createBuffer(
          size: 512,
          usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);

      final encoder = device.createCommandEncoder();
      final pass = encoder.beginComputePass();
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);
      pass.dispatchWorkgroups(1);
      pass.end();
      encoder.copyTextureToBuffer(tex, readback, bytesPerRow: 256);
      device.queue.submit([encoder.finish()]);
      final bytes = await readback.mapRead();
      // texel(0,0): v=0 → (0, 255, ~128); texel(1,1): v=0.75 → (~191, ~64).
      expect(bytes[0], 0);
      expect(bytes[1], 255);
      expect(bytes[256 + 4], inInclusiveRange(186, 196));
      expect(bytes[256 + 5], inInclusiveRange(59, 69));

      readback.dispose();
      bindGroup.dispose();
      view.dispose();
      tex.dispose();
      pipeline.dispose();
      module.dispose();
      layout.dispose();
      bgl.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('mip-level upload and single-mip views work', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final tex = device.createTexture(
        width: 4,
        height: 4,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
        mipLevelCount: 2,
      );
      // Write magenta into mip 1 (2×2).
      final mip1 = Uint8List.fromList(
          List.generate(4, (_) => [255, 0, 255, 255]).expand((p) => p).toList());
      device.queue
          .writeTexture(tex, mip1, mipLevel: 1, width: 2, height: 2);

      // Sample through a view restricted to mip 1 — must read magenta.
      final view =
          tex.createView(baseMipLevel: 1, mipLevelCount: 1);
      final sampler = device.createSampler(
          magFilter: GpuFilterMode.nearest, minFilter: GpuFilterMode.nearest);
      final module = await device.createShaderModule('''
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;
$fullscreenVs
@fragment
fn fs_main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
  return textureSample(tex, samp, frag.xy / 2.0);
}
''');
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
      final bglAuto = pipeline.getBindGroupLayout(0);
      final bindGroup = device.createBindGroup(layout: bglAuto, entries: [
        GpuSamplerBinding(binding: 0, sampler: sampler),
        GpuTextureBinding(binding: 1, view: view),
      ]);

      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final targetView = target.createView();
      final readback = device.createBuffer(
          size: 512,
          usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(view: targetView),
      ]);
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);
      pass.draw(3);
      pass.end();
      encoder.copyTextureToBuffer(target, readback, bytesPerRow: 256);
      device.queue.submit([encoder.finish()]);
      final bytes = await readback.mapRead();
      expect(bytes.sublist(0, 4), [255, 0, 255, 255],
          reason: 'mip-1 magenta sampled through a restricted view');

      readback.dispose();
      targetView.dispose();
      target.dispose();
      bindGroup.dispose();
      bglAuto.dispose();
      pipeline.dispose();
      module.dispose();
      sampler.dispose();
      view.dispose();
      tex.dispose();
      device.dispose();
      adapter.dispose();
    });
  });

  group('M2.x timestamp queries', () {
    test('measures real GPU time for a compute pass', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      if (!adapter.supportsTimestampQueries) {
        adapter.dispose();
        markTestSkipped('adapter lacks timestamp-query');
        return;
      }
      final device =
          await adapter.requestDevice(requireTimestampQueries: true);
      final queue = device.queue;
      expect(queue.timestampPeriod, greaterThan(0));

      final querySet = await device.createTimestampQuerySet(2);
      final resolve = device.createBuffer(
        size: 16,
        usage: GpuBufferUsage.queryResolve | GpuBufferUsage.copySrc,
      );
      final staging = device.createBuffer(
        size: 16,
        usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst,
      );
      final storage = device.createBuffer(
        size: 1024 * 4,
        usage: GpuBufferUsage.storage | GpuBufferUsage.copyDst,
      );
      queue.writeBuffer(
          storage, Float32List(1024).buffer.asUint8List());

      final module = await device.createShaderModule('''
@group(0) @binding(0) var<storage, read_write> data: array<f32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  var v = data[gid.x];
  for (var i = 0; i < 64; i++) { v = v * 1.0001 + 0.0001; }
  data[gid.x] = v;
}
''');
      final pipeline = await device.createComputePipeline(module: module);
      final layout = pipeline.getBindGroupLayout(0);
      final bindGroup = device.createBindGroup(layout: layout, entries: [
        GpuBufferBinding(binding: 0, buffer: storage),
      ]);

      final encoder = device.createCommandEncoder();
      final pass = encoder.beginComputePass(
        timestampWrites: GpuTimestampWrites(querySet: querySet),
      );
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);
      pass.dispatchWorkgroups(1024 ~/ 64);
      pass.end();
      encoder.resolveQuerySet(querySet, destination: resolve);
      encoder.copyBufferToBuffer(resolve, staging);
      queue.submit([encoder.finish()]);

      final bytes = await staging.mapRead();
      final stamps = bytes.buffer.asUint64List(bytes.offsetInBytes, 2);
      expect(stamps[1], greaterThan(stamps[0]),
          reason: 'end-of-pass timestamp must be after begin-of-pass');
      final ms =
          (stamps[1] - stamps[0]) * queue.timestampPeriod / 1e6;
      expect(ms, greaterThan(0));
      expect(ms, lessThan(1000), reason: 'sanity: a tiny pass, not seconds');

      bindGroup.dispose();
      layout.dispose();
      pipeline.dispose();
      module.dispose();
      storage.dispose();
      staging.dispose();
      resolve.dispose();
      querySet.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('query set creation without the feature throws', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice(); // no feature requested
      await expectLater(
        device.createTimestampQuerySet(2),
        throwsA(isA<GpuValidationException>()),
      );
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

    test('every benchmark scene compiles and builds a render pipeline',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      for (final (name, builder) in benchmarkScenes()) {
        final scene = builder() as UniformScene;
        final module =
            await device.createShaderModule(scene.wgsl, label: name);
        final pipeline = await device.createRenderPipeline(
          module: module,
          targetFormat: GpuTextureFormat.bgra8Unorm,
          label: name,
        );
        pipeline.dispose();
        module.dispose();
        scene.dispose();
      }
      device.dispose();
      adapter.dispose();
    });
  });

  group('example shader toy page', () {
    testWidgets('mounts, renders live, and unmounts cleanly', (tester) async {
      // Regression: the page's compile-error notifier must survive view
      // unmount order (it is owned by the page, not GpuSceneView).
      final binding = tester.binding as LiveTestWidgetsFlutterBinding;
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

      await tester.pumpWidget(const MaterialApp(home: ShaderToyPage()));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pump();

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 600)));
      await tester.pump();
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
