// Production-robustness suite: lifecycle soak, error paths, boundary
// values, concurrency, and editor-engine hardening. Complements the
// per-feature main suite and the cross-feature complex suite.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';
import 'adapter_support.dart';
import 'package:nitro_webgpu_example/src/gpu/particle_scene.dart';
import 'package:nitro_webgpu_example/src/gpu/scenes.dart';
import 'package:nitro_webgpu_example/src/gpu/shadertoy_engine.dart';

const kForceFallback = bool.fromEnvironment('WGPU_FORCE_FALLBACK');

const _fsTriVs = '''
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var p = array<vec2f, 3>(vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(p[i], 0.0, 1.0);
}
''';

Future<(GpuAdapter, GpuDevice)> boot() async {
  final adapter =
      await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
  final device = await adapter.requestDevice();
  return (adapter, device);
}

/// Renders [scene] into a fresh size×size rgba8 offscreen target for each
/// elapsed step and returns the final pixels (tight rows).
Future<Uint8List> renderScene(
    GpuDevice device, GpuScene scene, List<Duration> steps,
    {int size = 64}) async {
  final target = device.createTexture(
    width: size,
    height: size,
    format: GpuTextureFormat.rgba8Unorm,
    usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
  );
  final view = target.createView();
  final rt = GpuRenderTarget(
      view: view,
      width: size,
      height: size,
      targetFormat: GpuTextureFormat.rgba8Unorm);
  for (final t in steps) {
    await scene.render(device, rt, t);
  }
  // Buffer copies require 256-byte row alignment — rows sit 256 apart.
  final readback = device.createBuffer(
      size: 256 * size,
      usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
  final encoder = device.createCommandEncoder();
  encoder.copyTextureToBuffer(target, readback, bytesPerRow: 256);
  device.queue.submit([encoder.finish()]);
  final pixels = await readback.mapRead();
  readback.dispose();
  view.dispose();
  target.dispose();
  return pixels;
}

List<int> centerPixel(Uint8List pixels, {int size = 64}) {
  final at = (size ~/ 2) * 256 + (size ~/ 2) * 4;
  return pixels.sublist(at, at + 4);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('lifecycle soak', () {
    test('full object graph create+dispose x50 stays stable', () async {
      final (adapter, device) = await boot();
      final module = await device.createShaderModule('''
$_fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 0.0, 0.0, 1.0); }
''');
      for (var i = 0; i < 50; i++) {
        final buffer = device.createBuffer(
            size: 256,
            usage: GpuBufferUsage.storage | GpuBufferUsage.copyDst);
        final texture = device.createTexture(
          width: 16,
          height: 16,
          format: GpuTextureFormat.rgba8Unorm,
          usage:
              GpuTextureUsage.renderAttachment | GpuTextureUsage.textureBinding,
        );
        final view = texture.createView();
        final sampler = device.createSampler();
        final pipeline = await device.createRenderPipeline(
            module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
        final encoder = device.createCommandEncoder();
        final pass = encoder.beginRenderPass(
            colorAttachments: [GpuColorAttachmentInfo(view: view)]);
        pass.setPipeline(pipeline);
        pass.draw(3);
        pass.end();
        device.queue.submit([encoder.finish()]);
        pipeline.dispose();
        sampler.dispose();
        view.dispose();
        texture.dispose();
        buffer.dispose();
      }
      await device.queue.onSubmittedWorkDone();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('300-frame render soak ends pixel-correct', () async {
      final (adapter, device) = await boot();
      final engine = ShadertoyEngine(
        image: const ShadertoyPassSpec(
          language: ShadertoyLanguage.wgslSnippet,
          source: '''
fn mainImage(fragCoord: vec2f) -> vec4f {
  // Time-dependent everywhere except dead center, which stays green.
  let uv = fragCoord / iResolution.xy;
  if (distance(uv, vec2f(0.5)) < 0.1) { return vec4f(0.0, 1.0, 0.0, 1.0); }
  return vec4f(0.5 + 0.5 * sin(iTime), 0.0, 0.5, 1.0);
}''',
        ),
      );
      final steps =
          [for (var i = 1; i <= 300; i++) Duration(milliseconds: 16 * i)];
      final pixels = await renderScene(device, engine, steps);
      expect(centerPixel(pixels), [0, 255, 0, 255]);
      engine.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('shader hot-swap churn x30 (alternating good/bad) stays correct',
        () async {
      final (adapter, device) = await boot();
      final engine = ShadertoyEngine(
        image: const ShadertoyPassSpec(
          language: ShadertoyLanguage.wgslSnippet,
          source:
              'fn mainImage(fragCoord: vec2f) -> vec4f { return vec4f(0.0, 1.0, 0.0, 1.0); }',
        ),
      );
      var t = 0;
      Future<Uint8List> frame() =>
          renderScene(device, engine, [Duration(milliseconds: 16 * ++t)]);
      await frame();
      for (var i = 0; i < 30; i++) {
        if (i.isEven) {
          engine.setPass(
              4,
              const ShadertoyPassSpec(
                  language: ShadertoyLanguage.wgslSnippet,
                  source: 'fn mainImage(c: vec2f) -> vec4f { broken }'));
          await frame();
          expect(engine.compileError.value, isNotNull, reason: 'iter $i');
        } else {
          engine.setPass(
              4,
              const ShadertoyPassSpec(
                  language: ShadertoyLanguage.wgslSnippet,
                  source:
                      'fn mainImage(c: vec2f) -> vec4f { return vec4f(0.0, 1.0, 0.0, 1.0); }'));
          await frame();
          expect(engine.compileError.value, isNull, reason: 'iter $i');
        }
      }
      expect(centerPixel(await frame()), [0, 255, 0, 255],
          reason: 'still rendering the last good shader after 30 swaps');
      engine.dispose();
      device.dispose();
      adapter.dispose();
    });
  });

  group('error paths', () {
    test('use-after-dispose throws StateError, never touches native',
        () async {
      final (adapter, device) = await boot();
      final buffer = device.createBuffer(
          size: 64, usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      buffer.dispose();
      expect(() => buffer.mapRead(), throwsStateError);

      final queue = device.queue;
      device.dispose();
      expect(() => device.createCommandEncoder(), throwsStateError);
      expect(() => queue.writeBuffer, returnsNormally); // getter only
      adapter.dispose();
      expect(() => adapter.info, throwsStateError);
    });

    test('nested error scopes capture at the right depth', () async {
      final (adapter, device) = await boot();
      device.pushErrorScope(GpuErrorFilter.validation);
      device.pushErrorScope(GpuErrorFilter.validation);
      // Trigger a validation error in the INNER scope: mapRead may only
      // combine with copyDst — mapRead|mapWrite is invalid per spec.
      device.createBuffer(
          size: 16,
          usage: GpuBufferUsage.mapRead | GpuBufferUsage.mapWrite);
      final inner = await device.popErrorScope();
      final outer = await device.popErrorScope();
      expect(inner, isNotNull, reason: 'inner scope captured the error');
      expect(outer, isNull, reason: 'outer scope stays clean');
      device.dispose();
      adapter.dispose();
    });

    test('pipeline interface mismatches throw typed exceptions', () async {
      final (adapter, device) = await boot();
      final module = await device.createShaderModule('''
$_fsTriVs
@fragment
fn fs_main(@location(3) missing: vec4f) -> @location(0) vec4f {
  return missing;
}
''');
      await expectLater(
          device.createRenderPipeline(
              module: module, targetFormat: GpuTextureFormat.rgba8Unorm),
          throwsA(isA<GpuValidationException>()),
          reason: 'fragment consumes a vertex output that does not exist');
      await expectLater(
          device.createRenderPipeline(
              module: module,
              targetFormat: GpuTextureFormat.rgba8Unorm,
              vertexEntryPoint: 'nope'),
          throwsA(isA<GpuValidationException>()),
          reason: 'missing entry point');
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('zero-sized work is harmless', () async {
      final (adapter, device) = await boot();
      if (await skipWithoutCompute(device)) {
        device.dispose();
        adapter.dispose();
        return;
      }
      final module = await device.createShaderModule('''
$_fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(1.0); }
''');
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
      final compute = await device.createComputePipeline(
          module: await device.createShaderModule('''
@compute @workgroup_size(1)
fn main() {}
'''));
      final target = device.createTexture(
        width: 8,
        height: 8,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment,
      );
      final view = target.createView();
      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: view)]);
      pass.setPipeline(pipeline);
      pass.draw(0); // zero vertices
      pass.draw(3, instanceCount: 0); // zero instances
      pass.end();
      final cp = encoder.beginComputePass();
      cp.setPipeline(compute);
      cp.dispatchWorkgroups(0); // zero workgroups
      cp.end();
      // Empty passes too.
      encoder
          .beginRenderPass(
              colorAttachments: [GpuColorAttachmentInfo(view: view)])
          .end();
      device.queue.submit([encoder.finish()]);
      await device.queue.onSubmittedWorkDone();
      view.dispose();
      target.dispose();
      pipeline.dispose();
      compute.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });
  });

  group('boundary values', () {
    test('odd-width texture readback respects 256-byte row alignment',
        () async {
      final (adapter, device) = await boot();
      for (final width in [3, 63]) {
        const height = 5;
        final texture = device.createTexture(
          width: width,
          height: height,
          format: GpuTextureFormat.rgba8Unorm,
          usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
        );
        final view = texture.createView();
        final readback = device.createBuffer(
            size: 256 * height,
            usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
        final encoder = device.createCommandEncoder();
        encoder
            .beginRenderPass(colorAttachments: [
              GpuColorAttachmentInfo(
                  view: view, clearColor: const GpuColor(0, 0, 1)),
            ])
            .end();
        encoder.copyTextureToBuffer(texture, readback, bytesPerRow: 256);
        device.queue.submit([encoder.finish()]);
        final pixels = await readback.mapRead();
        for (var y = 0; y < height; y++) {
          final rowStart = y * 256;
          final lastTexel = rowStart + (width - 1) * 4;
          expect(pixels.sublist(lastTexel, lastTexel + 4), [0, 0, 255, 255],
              reason: 'width $width row $y last texel');
        }
        readback.dispose();
        view.dispose();
        texture.dispose();
      }
      device.dispose();
      adapter.dispose();
    });

    test('workgroup boundary counts 63/64/65 integrate every particle',
        () async {
      final (adapter, device) = await boot();
      if (await skipWithoutCompute(device)) {
        device.dispose();
        adapter.dispose();
        return;
      }
      for (final count in [63, 64, 65]) {
        final seed = Float32List(count * 4);
        for (var i = 0; i < count; i++) {
          seed[i * 4 + 2] = 1.0; // vel.x = 1
        }
        final scene = ParticleScene(count: count, initialParticles: seed)
          ..setKernel('''
struct Particle { pos: vec2f, vel: vec2f };
struct SimParams { dt: f32, time: f32, count: f32, size: f32 };
@group(0) @binding(0) var<uniform> params: SimParams;
@group(0) @binding(1) var<storage, read_write> particles: array<Particle>;
@compute @workgroup_size(64)
fn simulate(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i >= u32(params.count)) { return; }
  particles[i].pos += particles[i].vel * params.dt;
}''');
        await renderScene(device, scene,
            [Duration.zero, const Duration(milliseconds: 16)]);
        final staging = device.createBuffer(
            size: count * 16,
            usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
        final encoder = device.createCommandEncoder();
        encoder.copyBufferToBuffer(scene.particleBuffer!, staging);
        device.queue.submit([encoder.finish()]);
        final data = Float32List.view((await staging.mapRead()).buffer);
        for (var i = 0; i < count; i++) {
          expect(data[i * 4], closeTo(0.016, 1e-4),
              reason: 'count $count particle $i moved');
        }
        staging.dispose();
        scene.dispose();
      }
      device.dispose();
      adapter.dispose();
    });

    test('partial writeBuffer at an offset and windowed mapRead', () async {
      final (adapter, device) = await boot();
      final buffer = device.createBuffer(
          size: 64, usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      device.queue
          .writeBuffer(buffer, Uint8List.fromList([1, 2, 3, 4]), bufferOffset: 8);
      device.queue.writeBuffer(buffer, Uint8List.fromList([9, 9, 9, 9]),
          bufferOffset: 60);
      // Spec alignment rules surface as crisp ArgumentErrors.
      expect(() => device.queue.writeBuffer(buffer, Uint8List(2)),
          throwsArgumentError);
      expect(
          () => device.queue
              .writeBuffer(buffer, Uint8List(4), bufferOffset: 2),
          throwsArgumentError);
      // writeBuffer stages data on the queue; a submit (even an empty one)
      // flushes it before the map resolves.
      final flush = device.createCommandEncoder();
      device.queue.submit([flush.finish()]);
      final window = await buffer.mapRead(offset: 8, size: 8);
      expect(window.sublist(0, 4), [1, 2, 3, 4]);
      final tail = await buffer.mapRead(offset: 56, size: 8);
      expect(tail.sublist(4, 8), [9, 9, 9, 9]);
      buffer.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('mip-level upload uses mip-aware default dimensions', () async {
      final (adapter, device) = await boot();
      final texture = device.createTexture(
        width: 8,
        height: 8,
        mipLevelCount: 3,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.copyDst | GpuTextureUsage.copySrc,
      );
      // Mip 1 is 4×4 — rely on the mip-aware defaults (no width/height).
      final mip1 = Uint8List(4 * 4 * 4);
      for (var i = 0; i < 16; i++) {
        mip1[i * 4] = 200;
        mip1[i * 4 + 3] = 255;
      }
      device.queue.writeTexture(texture, mip1, mipLevel: 1);
      final readback = device.createBuffer(
          size: 256 * 4,
          usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      final encoder = device.createCommandEncoder();
      encoder.copyTextureToBuffer(texture, readback,
          bytesPerRow: 256, mipLevel: 1);
      device.queue.submit([encoder.finish()]);
      final pixels = await readback.mapRead();
      expect(pixels.sublist(0, 4), [200, 0, 0, 255]);
      expect(pixels.sublist(3 * 256 + 3 * 4, 3 * 256 + 3 * 4 + 4),
          [200, 0, 0, 255]);
      readback.dispose();
      texture.dispose();
      device.dispose();
      adapter.dispose();
    });
  });

  group('concurrency', () {
    test('8 concurrent off-thread shader+pipeline creates all resolve',
        () async {
      final (adapter, device) = await boot();
      final futures = [
        for (var i = 0; i < 8; i++)
          () async {
            final module = await device.createShaderModule('''
$_fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f {
  return vec4f(${i / 8}, 0.0, 0.0, 1.0);
}
''');
            final pipeline = await device.createRenderPipeline(
                module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
            return (module, pipeline);
          }()
      ];
      final results = await Future.wait(futures);
      expect(results.length, 8);
      for (final (module, pipeline) in results) {
        pipeline.dispose();
        module.dispose();
      }
      device.dispose();
      adapter.dispose();
    });

    test('two devices render interleaved frames', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final deviceA = await adapter.requestDevice(label: 'A');
      final deviceB = await adapter.requestDevice(label: 'B');
      final engineA = ShadertoyEngine(
          image: const ShadertoyPassSpec(
              language: ShadertoyLanguage.wgslSnippet,
              source:
                  'fn mainImage(c: vec2f) -> vec4f { return vec4f(1.0, 0.0, 0.0, 1.0); }'));
      final engineB = ShadertoyEngine(
          image: const ShadertoyPassSpec(
              language: ShadertoyLanguage.wgslSnippet,
              source:
                  'fn mainImage(c: vec2f) -> vec4f { return vec4f(0.0, 0.0, 1.0, 1.0); }'));
      Uint8List? lastA, lastB;
      for (var i = 1; i <= 20; i++) {
        lastA = await renderScene(
            deviceA, engineA, [Duration(milliseconds: 16 * i)]);
        lastB = await renderScene(
            deviceB, engineB, [Duration(milliseconds: 16 * i)]);
      }
      expect(centerPixel(lastA!), [255, 0, 0, 255]);
      expect(centerPixel(lastB!), [0, 0, 255, 255]);
      engineA.dispose();
      engineB.dispose();
      deviceA.dispose();
      deviceB.dispose();
      adapter.dispose();
    });
  });

  group('editor engine hardening', () {
    test('full A→B→C→D→Image chain propagates one stage per frame',
        () async {
      final (adapter, device) = await boot();
      ShadertoyPassSpec reader(ShadertoyChannelKind from) => ShadertoyPassSpec(
            language: ShadertoyLanguage.wgslSnippet,
            source:
                'fn mainImage(c: vec2f) -> vec4f { return textureSampleLevel(iChannel0, stSampler, vec2f(0.5), 0.0); }',
            channels: [
              ShadertoyChannel.buffer(from),
              const ShadertoyChannel.none(),
              const ShadertoyChannel.none(),
              const ShadertoyChannel.none(),
            ],
          );
      final engine = ShadertoyEngine(
        buffers: [
          const ShadertoyPassSpec(
              language: ShadertoyLanguage.wgslSnippet,
              source:
                  'fn mainImage(c: vec2f) -> vec4f { return vec4f(0.25, 0.0, 0.0, 1.0); }'),
          reader(ShadertoyChannelKind.bufferA),
          reader(ShadertoyChannelKind.bufferB),
          reader(ShadertoyChannelKind.bufferC),
        ],
        image: reader(ShadertoyChannelKind.bufferD),
      );
      Future<Uint8List> at(int frames) => renderScene(device, engine,
          [for (var i = 1; i <= frames; i++) Duration(milliseconds: 16 * i)]);
      // Value 0.25 propagates A→B→C→D→Image one stage per frame: the Image
      // pass reads D's previous frame, so red arrives on frame 5.
      final early = await at(4);
      expect(centerPixel(early)[0], 0, reason: 'not propagated yet');
      final done = await renderScene(device, engine,
          [const Duration(milliseconds: 16 * 5)]);
      expect(centerPixel(done)[0], closeTo(64, 2),
          reason: '0.25 arrived at the Image pass');
      engine.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('resize mid-run recreates buffer targets safely', () async {
      final (adapter, device) = await boot();
      final engine = ShadertoyEngine(
        buffers: const [
          ShadertoyPassSpec(
              language: ShadertoyLanguage.wgslSnippet,
              source:
                  'fn mainImage(c: vec2f) -> vec4f { return vec4f(0.0, 1.0, 0.0, 1.0); }'),
        ],
        image: const ShadertoyPassSpec(
          language: ShadertoyLanguage.wgslSnippet,
          source:
              'fn mainImage(c: vec2f) -> vec4f { return textureSampleLevel(iChannel0, stSampler, vec2f(0.5), 0.0); }',
          channels: [
            ShadertoyChannel.buffer(ShadertoyChannelKind.bufferA),
            ShadertoyChannel.none(),
            ShadertoyChannel.none(),
            ShadertoyChannel.none(),
          ],
        ),
      );
      await renderScene(device, engine,
          [const Duration(milliseconds: 16), const Duration(milliseconds: 32)],
          size: 64);
      await renderScene(device, engine,
          [const Duration(milliseconds: 48), const Duration(milliseconds: 64)],
          size: 32);
      final pixels = await renderScene(device, engine,
          [const Duration(milliseconds: 80), const Duration(milliseconds: 96)],
          size: 64);
      expect(centerPixel(pixels), [0, 255, 0, 255],
          reason: 'buffer chain still correct after two resizes');
      engine.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('GLSL and WGSL passes mix in one engine', () async {
      final (adapter, device) = await boot();
      if (await skipWithoutGlsl(device)) {
        device.dispose();
        adapter.dispose();
        return;
      }
      final engine = ShadertoyEngine(
        buffers: const [
          // Buffer A in GLSL writes solid red.
          ShadertoyPassSpec(
              language: ShadertoyLanguage.glsl,
              source: '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = vec4(1.0, 0.0, 0.0, 1.0);
}'''),
        ],
        image: const ShadertoyPassSpec(
          // Image in WGSL samples it.
          language: ShadertoyLanguage.wgslSnippet,
          source:
              'fn mainImage(c: vec2f) -> vec4f { return textureSampleLevel(iChannel0, stSampler, vec2f(0.5), 0.0); }',
          channels: [
            ShadertoyChannel.buffer(ShadertoyChannelKind.bufferA),
            ShadertoyChannel.none(),
            ShadertoyChannel.none(),
            ShadertoyChannel.none(),
          ],
        ),
      );
      final pixels = await renderScene(device, engine, [
        const Duration(milliseconds: 16),
        const Duration(milliseconds: 32),
      ]);
      expect(centerPixel(pixels), [255, 0, 0, 255]);
      engine.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('particle kernel swap preserves the storage buffer contents',
        () async {
      final (adapter, device) = await boot();
      if (await skipWithoutCompute(device)) {
        device.dispose();
        adapter.dispose();
        return;
      }
      final scene = ParticleScene(
          count: 1,
          initialParticles: Float32List.fromList([0.25, 0.5, 0.0, 0.0]));
      await renderScene(device, scene, [Duration.zero]);
      scene.setKernel('''
struct Particle { pos: vec2f, vel: vec2f };
struct SimParams { dt: f32, time: f32, count: f32, size: f32 };
@group(0) @binding(0) var<uniform> params: SimParams;
@group(0) @binding(1) var<storage, read_write> particles: array<Particle>;
@compute @workgroup_size(64)
fn simulate(@builtin(global_invocation_id) gid: vec3<u32>) {
  // No-op kernel — positions must be untouched.
}''');
      await renderScene(
          device, scene, [const Duration(milliseconds: 16)]);
      final staging = device.createBuffer(
          size: 16, usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      final encoder = device.createCommandEncoder();
      encoder.copyBufferToBuffer(scene.particleBuffer!, staging);
      device.queue.submit([encoder.finish()]);
      final data = Float32List.view((await staging.mapRead()).buffer);
      expect(data[0], closeTo(0.25, 1e-6));
      expect(data[1], closeTo(0.5, 1e-6));
      staging.dispose();
      scene.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('100k particles render one frame without incident', () async {
      final (adapter, device) = await boot();
      if (await skipWithoutCompute(device)) {
        device.dispose();
        adapter.dispose();
        return;
      }
      final scene = ParticleScene(count: 100000);
      final pixels = await renderScene(device, scene, [
        Duration.zero,
        const Duration(milliseconds: 16),
      ]);
      var lit = 0;
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final i = y * 256 + x * 4;
          if (pixels[i] > 0 || pixels[i + 1] > 0 || pixels[i + 2] > 0) lit++;
        }
      }
      expect(lit, greaterThan(100), reason: 'particles cover pixels');
      scene.dispose();
      device.dispose();
      adapter.dispose();
    });
  });
}
