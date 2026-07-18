// Complex parity checks: each test combines several WebGPU features the way
// a real renderer would (GPU-driven draws, deferred shading, frame graphs),
// so regressions in feature *interactions* surface even when the isolated
// feature tests stay green.
import 'dart:io' show Platform;

import 'adapter_support.dart';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

const bool kForceFallback = bool.fromEnvironment('WGPU_FORCE_FALLBACK');

/// Fullscreen-triangle vertex stage used by verification passes.
const fsTriVs = '''
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}
''';

/// Reads a small rgba8 texture back. Rows are 256-byte aligned: pixel (x, y)
/// starts at `y * 256 + x * 4`.
Future<Uint8List> readbackRgba(GpuDevice device, GpuTexture texture) async {
  final buffer = device.createBuffer(
      size: 256 * texture.height,
      usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
  final encoder = device.createCommandEncoder();
  encoder.copyTextureToBuffer(texture, buffer, bytesPerRow: 256);
  device.queue.submit([encoder.finish()]);
  final bytes = await buffer.mapRead();
  buffer.dispose();
  return bytes;
}

List<int> pixel(Uint8List bytes, int x, int y) =>
    bytes.sublist(y * 256 + x * 4, y * 256 + x * 4 + 4);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('complex parity', () {
    test(
        'GPU-driven frame: compute generates vertices, indirect args, and a '
        'texture; render consumes all three (+ timestamps)', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final hasTs = adapter.supportsTimestampQueries;
      final device =
          await adapter.requestDevice(requireTimestampQueries: hasTs);
      if (await skipWithoutCompute(device)) {
        device.dispose();
        adapter.dispose();
        return;
      }

      // One compute dispatch fills a vertex buffer (fullscreen triangle),
      // indirect draw args, and a storage texture — the render pass then
      // draws entirely from GPU-written state.
      final computeModule = await device.createShaderModule('''
@group(0) @binding(0) var<storage, read_write> verts: array<vec2f>;
@group(0) @binding(1) var<storage, read_write> args: array<u32>;
@group(0) @binding(2) var img: texture_storage_2d<rgba8unorm, write>;

@compute @workgroup_size(1)
fn main() {
  verts[0] = vec2f(-1.0, -3.0);
  verts[1] = vec2f(3.0, 1.0);
  verts[2] = vec2f(-1.0, 1.0);
  args[0] = 3u; args[1] = 1u; args[2] = 0u; args[3] = 0u;
  for (var x = 0; x < 2; x++) {
    for (var y = 0; y < 2; y++) {
      textureStore(img, vec2i(x, y), vec4f(1.0, 0.0, 1.0, 1.0));
    }
  }
}
''');
      final computeBgl = device.createBindGroupLayout(entries: const [
        GpuLayoutEntry(
            binding: 0,
            visibility: GpuShaderStage.compute,
            type: GpuBindingType.storageBuffer),
        GpuLayoutEntry(
            binding: 1,
            visibility: GpuShaderStage.compute,
            type: GpuBindingType.storageBuffer),
        GpuLayoutEntry(
            binding: 2,
            visibility: GpuShaderStage.compute,
            type: GpuBindingType.storageTexture),
      ]);
      final computeLayout = device.createPipelineLayout(layouts: [computeBgl]);
      final computePipeline = await device.createComputePipeline(
          module: computeModule, layout: computeLayout);

      final vbuf = device.createBuffer(
          size: 24, usage: GpuBufferUsage.storage | GpuBufferUsage.vertex);
      final argsBuf = device.createBuffer(
          size: 16, usage: GpuBufferUsage.storage | GpuBufferUsage.indirect);
      final genTex = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage:
            GpuTextureUsage.storageBinding | GpuTextureUsage.textureBinding,
      );
      final genView = genTex.createView();
      final computeBind = device.createBindGroup(layout: computeBgl, entries: [
        GpuBufferBinding(binding: 0, buffer: vbuf),
        GpuBufferBinding(binding: 1, buffer: argsBuf),
        GpuTextureBinding(binding: 2, view: genView),
      ]);

      final renderModule = await device.createShaderModule('''
@group(0) @binding(0) var tex: texture_2d<f32>;
@vertex
fn vs_main(@location(0) pos: vec2f) -> @builtin(position) vec4f {
  return vec4f(pos, 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4f {
  return textureLoad(tex, vec2i(0, 0), 0);
}
''');
      final renderPipeline = await device.createRenderPipeline(
        module: renderModule,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        vertexBuffers: [
          GpuVertexLayout(arrayStride: 8, attributes: const [
            GpuVertexAttr(
                format: GpuVertexFormat.float32x2,
                offset: 0,
                shaderLocation: 0),
          ]),
        ],
      );
      final renderBgl = renderPipeline.getBindGroupLayout(0);
      final renderBind = device.createBindGroup(layout: renderBgl, entries: [
        GpuTextureBinding(binding: 0, view: genView),
      ]);

      final querySet = hasTs ? await device.createTimestampQuerySet(4) : null;
      final tsResolve = hasTs
          ? device.createBuffer(
              size: 32,
              usage: GpuBufferUsage.queryResolve | GpuBufferUsage.copySrc)
          : null;
      final tsStaging = hasTs
          ? device.createBuffer(
              size: 32,
              usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst)
          : null;

      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final targetView = target.createView();
      final readback = device.createBuffer(
          size: 512, usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);

      final encoder = device.createCommandEncoder();
      final computePass = encoder.beginComputePass(
        timestampWrites: querySet != null
            ? GpuTimestampWrites(querySet: querySet, beginIndex: 0, endIndex: 1)
            : null,
      );
      computePass.setPipeline(computePipeline);
      computePass.setBindGroup(0, computeBind);
      computePass.dispatchWorkgroups(1);
      computePass.end();

      final renderPass = encoder.beginRenderPass(
        colorAttachments: [GpuColorAttachmentInfo(view: targetView)],
        timestampWrites: querySet != null
            ? GpuTimestampWrites(querySet: querySet, beginIndex: 2, endIndex: 3)
            : null,
      );
      renderPass.setPipeline(renderPipeline);
      renderPass.setBindGroup(0, renderBind);
      renderPass.setVertexBuffer(0, vbuf);
      renderPass.drawIndirect(argsBuf);
      renderPass.end();

      encoder.copyTextureToBuffer(target, readback, bytesPerRow: 256);
      if (querySet != null) {
        encoder.resolveQuerySet(querySet, destination: tsResolve!);
        encoder.copyBufferToBuffer(tsResolve, tsStaging!);
      }
      device.queue.submit([encoder.finish()]);

      final bytes = await readback.mapRead();
      for (final (x, y) in [(0, 0), (1, 0), (0, 1), (1, 1)]) {
        expect(pixel(bytes, x, y), [255, 0, 255, 255],
            reason: 'GPU-generated magenta at ($x,$y)');
      }
      if (hasTs) {
        final ticksBytes = await tsStaging!.mapRead();
        final ticks =
            ticksBytes.buffer.asUint64List(ticksBytes.offsetInBytes, 4);
        expect(ticks[1], greaterThanOrEqualTo(ticks[0]),
            reason: 'compute pass end >= begin');
        expect(ticks[3], greaterThanOrEqualTo(ticks[2]),
            reason: 'render pass end >= begin');
      }

      readback.dispose();
      tsStaging?.dispose();
      tsResolve?.dispose();
      querySet?.dispose();
      targetView.dispose();
      target.dispose();
      renderBind.dispose();
      renderBgl.dispose();
      renderPipeline.dispose();
      renderModule.dispose();
      computeBind.dispose();
      genView.dispose();
      genTex.dispose();
      argsBuf.dispose();
      vbuf.dispose();
      computePipeline.dispose();
      computeLayout.dispose();
      computeBgl.dispose();
      computeModule.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('deferred shading: MRT G-buffer pass feeds a lighting pass',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final gBufferModule = await device.createShaderModule('''
struct FOut {
  @location(0) albedo: vec4f,
  @location(1) normal: vec4f,
};
$fsTriVs
@fragment
fn fs_main() -> FOut {
  var o: FOut;
  o.albedo = vec4f(1.0, 0.0, 0.0, 1.0);
  o.normal = vec4f(0.0, 0.0, 1.0, 1.0);
  return o;
}
''');
      final gBufferPipeline = await device.createRenderPipeline(
        module: gBufferModule,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        extraTargetFormats: [GpuTextureFormat.rgba8Unorm],
      );

      GpuTexture makeGBuffer() => device.createTexture(
            width: 2,
            height: 2,
            format: GpuTextureFormat.rgba8Unorm,
            usage: GpuTextureUsage.renderAttachment |
                GpuTextureUsage.textureBinding,
          );
      final albedoTex = makeGBuffer();
      final normalTex = makeGBuffer();
      final albedoView = albedoTex.createView();
      final normalView = normalTex.createView();

      // Lighting pass proves BOTH targets were written and are readable:
      // output = (albedo.r, normal.b, 0, 1) = yellow.
      final lightingModule = await device.createShaderModule('''
@group(0) @binding(0) var albedo: texture_2d<f32>;
@group(0) @binding(1) var normal: texture_2d<f32>;
$fsTriVs
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let a = textureLoad(albedo, vec2i(pos.xy), 0);
  let n = textureLoad(normal, vec2i(pos.xy), 0);
  return vec4f(a.r, n.b, 0.0, 1.0);
}
''');
      final lightingPipeline = await device.createRenderPipeline(
          module: lightingModule, targetFormat: GpuTextureFormat.rgba8Unorm);
      final lightingBgl = lightingPipeline.getBindGroupLayout(0);
      final lightingBind = device.createBindGroup(
        layout: lightingBgl,
        entries: [
          GpuTextureBinding(binding: 0, view: albedoView),
          GpuTextureBinding(binding: 1, view: normalView),
        ],
      );

      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final targetView = target.createView();

      final encoder = device.createCommandEncoder();
      final gPass = encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(view: albedoView),
        GpuColorAttachmentInfo(view: normalView),
      ]);
      gPass.setPipeline(gBufferPipeline);
      gPass.draw(3);
      gPass.end();

      final lightPass = encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: targetView)]);
      lightPass.setPipeline(lightingPipeline);
      lightPass.setBindGroup(0, lightingBind);
      lightPass.draw(3);
      lightPass.end();
      device.queue.submit([encoder.finish()]);

      final bytes = await readbackRgba(device, target);
      expect(pixel(bytes, 0, 0), [255, 255, 0, 255],
          reason: 'lighting combined albedo.r and normal.b');

      targetView.dispose();
      target.dispose();
      lightingBind.dispose();
      lightingBgl.dispose();
      lightingPipeline.dispose();
      lightingModule.dispose();
      normalView.dispose();
      albedoView.dispose();
      normalTex.dispose();
      albedoTex.dispose();
      gBufferPipeline.dispose();
      gBufferModule.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('mip chain: per-mip render targets sampled back by explicit level',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final mipTex = device.createTexture(
        width: 8,
        height: 8,
        format: GpuTextureFormat.rgba8Unorm,
        usage:
            GpuTextureUsage.renderAttachment | GpuTextureUsage.textureBinding,
        mipLevelCount: 3,
      );
      const mipColors = [
        GpuColor(1, 0, 0), // level 0: red
        GpuColor(0, 1, 0), // level 1: green
        GpuColor(0, 0, 1), // level 2: blue
      ];

      // Clear each mip level through a mip-restricted view.
      final encoder = device.createCommandEncoder();
      final mipViews = <GpuTextureView>[];
      for (var level = 0; level < 3; level++) {
        final view =
            mipTex.createView(baseMipLevel: level, mipLevelCount: 1);
        mipViews.add(view);
        encoder
            .beginRenderPass(colorAttachments: [
              GpuColorAttachmentInfo(view: view, clearColor: mipColors[level])
            ])
            .end();
      }

      // Verification pass: pixel x samples mip level x (clamped to 2).
      final module = await device.createShaderModule('''
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;
$fsTriVs
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  return textureSampleLevel(tex, samp, vec2f(0.5, 0.5), f32(i32(pos.x)));
}
''');
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
      final sampler = device.createSampler(
          magFilter: GpuFilterMode.nearest, minFilter: GpuFilterMode.nearest);
      final fullView = mipTex.createView();
      final bgl = pipeline.getBindGroupLayout(0);
      final bind = device.createBindGroup(layout: bgl, entries: [
        GpuSamplerBinding(binding: 0, sampler: sampler),
        GpuTextureBinding(binding: 1, view: fullView),
      ]);

      final target = device.createTexture(
        width: 4,
        height: 1,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final targetView = target.createView();
      final pass = encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: targetView)]);
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bind);
      pass.draw(3);
      pass.end();
      device.queue.submit([encoder.finish()]);

      final bytes = await readbackRgba(device, target);
      expect(pixel(bytes, 0, 0), [255, 0, 0, 255], reason: 'mip 0 red');
      expect(pixel(bytes, 1, 0), [0, 255, 0, 255], reason: 'mip 1 green');
      expect(pixel(bytes, 2, 0), [0, 0, 255, 255], reason: 'mip 2 blue');
      expect(pixel(bytes, 3, 0), [0, 0, 255, 255],
          reason: 'level 3 clamps to the last mip');

      targetView.dispose();
      target.dispose();
      bind.dispose();
      bgl.dispose();
      fullView.dispose();
      sampler.dispose();
      pipeline.dispose();
      module.dispose();
      for (final v in mipViews) {
        v.dispose();
      }
      mipTex.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('texture array + instancing: each instance samples its own layer',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      const layerColors = [
        [255, 0, 0, 255],
        [0, 255, 0, 255],
        [0, 0, 255, 255],
        [255, 255, 255, 255],
      ];
      final arrayTex = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
        depthOrArrayLayers: 4,
      );
      for (var layer = 0; layer < 4; layer++) {
        final data = Uint8List.fromList(
            List.generate(4, (_) => layerColors[layer]).expand((p) => p).toList());
        device.queue.writeTexture(arrayTex, data, arrayLayer: layer);
      }
      final arrayView =
          arrayTex.createView(dimension: GpuTextureViewDimension.d2Array);

      // 4 instances, one per quadrant of a 2×2 target; the flat-interpolated
      // instance index selects the array layer.
      final module = await device.createShaderModule('''
struct VOut {
  @builtin(position) pos: vec4f,
  @location(0) @interpolate(flat) layer: u32,
};
@group(0) @binding(0) var tex: texture_2d_array<f32>;

@vertex
fn vs_main(@builtin(vertex_index) vi: u32,
           @builtin(instance_index) ii: u32) -> VOut {
  var corners = array<vec2f, 6>(
      vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(0.0, 1.0),
      vec2f(0.0, 1.0), vec2f(1.0, 0.0), vec2f(1.0, 1.0));
  let quad = vec2f(f32(ii % 2u), f32(ii / 2u));
  var o: VOut;
  o.pos = vec4f(quad + corners[vi] - vec2f(1.0), 0.0, 1.0);
  o.layer = ii;
  return o;
}
@fragment
fn fs_main(v: VOut) -> @location(0) vec4f {
  return textureLoad(tex, vec2i(0, 0), i32(v.layer), 0);
}
''');
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
      final bgl = pipeline.getBindGroupLayout(0);
      final bind = device.createBindGroup(layout: bgl, entries: [
        GpuTextureBinding(binding: 0, view: arrayView),
      ]);

      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final targetView = target.createView();
      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: targetView)]);
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bind);
      pass.draw(6, instanceCount: 4);
      pass.end();
      device.queue.submit([encoder.finish()]);

      // NDC y is up, readback rows are top-down: top row = instances 2, 3.
      final bytes = await readbackRgba(device, target);
      expect(pixel(bytes, 0, 0), layerColors[2]);
      expect(pixel(bytes, 1, 0), layerColors[3]);
      expect(pixel(bytes, 0, 1), layerColors[0]);
      expect(pixel(bytes, 1, 1), layerColors[1]);

      targetView.dispose();
      target.dispose();
      bind.dispose();
      bgl.dispose();
      pipeline.dispose();
      module.dispose();
      arrayView.dispose();
      arrayTex.dispose();
      device.dispose();
      adapter.dispose();
    });

    test(
        'render bundle carries full draw state (vertex/index/bind group) '
        'and replays into two different passes', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final module = await device.createShaderModule('''
@group(0) @binding(0) var<uniform> tint: vec4f;
@vertex
fn vs_main(@location(0) pos: vec2f) -> @builtin(position) vec4f {
  return vec4f(pos, 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4f { return tint; }
''');
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        vertexBuffers: [
          GpuVertexLayout(arrayStride: 8, attributes: const [
            GpuVertexAttr(
                format: GpuVertexFormat.float32x2,
                offset: 0,
                shaderLocation: 0),
          ]),
        ],
      );

      final quad = Float32List.fromList([-1, -1, 1, -1, -1, 1, 1, 1]);
      final indices = Uint16List.fromList([0, 1, 2, 2, 1, 3]);
      final vbuf = device.createBuffer(
          size: quad.lengthInBytes,
          usage: GpuBufferUsage.vertex | GpuBufferUsage.copyDst);
      final ibuf = device.createBuffer(
          size: indices.lengthInBytes,
          usage: GpuBufferUsage.index | GpuBufferUsage.copyDst);
      device.queue.writeBuffer(vbuf, quad.buffer.asUint8List());
      device.queue.writeBuffer(ibuf, indices.buffer.asUint8List());

      final tint = device.createBuffer(
          size: 16, usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst);
      device.queue.writeBuffer(
          tint, Float32List.fromList([0, 1, 1, 1]).buffer.asUint8List());
      final bgl = pipeline.getBindGroupLayout(0);
      final bind = device.createBindGroup(layout: bgl, entries: [
        GpuBufferBinding(binding: 0, buffer: tint),
      ]);

      final bundleEncoder = device.createRenderBundleEncoder(
          colorFormats: [GpuTextureFormat.rgba8Unorm]);
      bundleEncoder.setPipeline(pipeline);
      bundleEncoder.setBindGroup(0, bind);
      bundleEncoder.setVertexBuffer(0, vbuf);
      bundleEncoder.setIndexBuffer(ibuf, GpuIndexFormat.uint16);
      bundleEncoder.drawIndexed(6);
      final bundle = bundleEncoder.finish();

      GpuTexture makeTarget() => device.createTexture(
            width: 2,
            height: 2,
            format: GpuTextureFormat.rgba8Unorm,
            usage:
                GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
          );
      final targetA = makeTarget();
      final targetB = makeTarget();
      final viewA = targetA.createView();
      final viewB = targetB.createView();

      final encoder = device.createCommandEncoder();
      encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(view: viewA)
      ])
        ..executeBundle(bundle)
        ..end();
      encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(view: viewB, clearColor: const GpuColor(1, 0, 0))
      ])
        ..executeBundle(bundle)
        ..end();
      device.queue.submit([encoder.finish()]);

      expect(pixel(await readbackRgba(device, targetA), 0, 0),
          [0, 255, 255, 255]);
      expect(pixel(await readbackRgba(device, targetB), 1, 1),
          [0, 255, 255, 255],
          reason: 'same bundle replayed over a red clear');

      viewB.dispose();
      viewA.dispose();
      targetB.dispose();
      targetA.dispose();
      bundle.dispose();
      bind.dispose();
      bgl.dispose();
      tint.dispose();
      ibuf.dispose();
      vbuf.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('compute-pass dynamic offsets: two dispatches, two uniform slices',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      if (await skipWithoutCompute(device)) {
        device.dispose();
        adapter.dispose();
        return;
      }

      final module = await device.createShaderModule('''
struct Params { m: f32 };
@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read_write> data: array<f32>;

@compute @workgroup_size(4)
fn main(@builtin(global_invocation_id) gid: vec3u) {
  data[gid.x] = data[gid.x] * params.m;
}
''');
      final bgl = device.createBindGroupLayout(entries: const [
        GpuLayoutEntry(
            binding: 0,
            visibility: GpuShaderStage.compute,
            type: GpuBindingType.uniformBuffer,
            hasDynamicOffset: true),
        GpuLayoutEntry(
            binding: 1,
            visibility: GpuShaderStage.compute,
            type: GpuBindingType.storageBuffer),
      ]);
      final layout = device.createPipelineLayout(layouts: [bgl]);
      final pipeline =
          await device.createComputePipeline(module: module, layout: layout);

      // Multiplier 2.0 at offset 0, 3.0 at offset 256.
      final params = device.createBuffer(
          size: 512, usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst);
      final paramData = Uint8List(512);
      paramData.buffer.asFloat32List(0, 1)[0] = 2.0;
      paramData.buffer.asFloat32List(256, 1)[0] = 3.0;
      device.queue.writeBuffer(params, paramData);

      final data = device.createBuffer(
          size: 16,
          usage: GpuBufferUsage.storage |
              GpuBufferUsage.copyDst |
              GpuBufferUsage.copySrc);
      device.queue.writeBuffer(
          data, Float32List.fromList([1, 2, 3, 4]).buffer.asUint8List());

      final bind = device.createBindGroup(layout: bgl, entries: [
        GpuBufferBinding(binding: 0, buffer: params, size: 16),
        GpuBufferBinding(binding: 1, buffer: data),
      ]);

      final staging = device.createBuffer(
          size: 16, usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      final encoder = device.createCommandEncoder();
      final pass = encoder.beginComputePass();
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bind, dynamicOffsets: [0]);
      pass.dispatchWorkgroups(1); // ×2
      pass.setBindGroup(0, bind, dynamicOffsets: [256]);
      pass.dispatchWorkgroups(1); // ×3
      pass.end();
      encoder.copyBufferToBuffer(data, staging);
      device.queue.submit([encoder.finish()]);

      final bytes = await staging.mapRead();
      final result = bytes.buffer.asFloat32List(bytes.offsetInBytes, 4);
      expect(result, [6, 12, 18, 24],
          reason: 'both uniform slices applied: ×2 then ×3');

      staging.dispose();
      bind.dispose();
      data.dispose();
      params.dispose();
      pipeline.dispose();
      layout.dispose();
      bgl.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test(
        'stencil incrementClamp + scissor: spatially varying stencil counts '
        'mask a final draw', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final writerModule = await device.createShaderModule('''
$fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 0.0, 0.0, 1.0); }
''');
      final writer = await device.createRenderPipeline(
        module: writerModule,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        depthFormat: GpuTextureFormat.depth24PlusStencil8,
        depthWriteEnabled: false,
        depthCompare: GpuCompareFunction.always,
        stencilPassOp: GpuStencilOperation.incrementClamp,
      );

      final testerModule = await device.createShaderModule('''
$fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(0.0, 1.0, 0.0, 1.0); }
''');
      final tester = await device.createRenderPipeline(
        module: testerModule,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        depthFormat: GpuTextureFormat.depth24PlusStencil8,
        depthWriteEnabled: false,
        depthCompare: GpuCompareFunction.always,
        stencilCompare: GpuCompareFunction.equal,
      );

      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final depthTex = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.depth24PlusStencil8,
        usage: GpuTextureUsage.renderAttachment,
      );
      final targetView = target.createView();
      final depthView = depthTex.createView();

      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(
        colorAttachments: [GpuColorAttachmentInfo(view: targetView)],
        depthAttachment: GpuDepthAttachmentInfo(
          view: depthView,
          stencilLoadOp: GpuLoadOp.clear,
          stencilStoreOp: GpuStoreOp.discard,
        ),
      );
      pass.setViewport(0, 0, 2, 2, minDepth: 0, maxDepth: 1);
      pass.setPipeline(writer);
      pass.draw(3); // whole target: red, stencil 1
      pass.setScissorRect(1, 0, 1, 2);
      pass.draw(3); // right column only: stencil 2
      pass.setScissorRect(0, 0, 2, 2);
      pass.setStencilReference(2);
      pass.setPipeline(tester);
      pass.draw(3); // green where stencil == 2
      pass.end();
      device.queue.submit([encoder.finish()]);

      final bytes = await readbackRgba(device, target);
      expect(pixel(bytes, 0, 0), [255, 0, 0, 255],
          reason: 'left column: stencil 1 ≠ 2, writer red survives');
      expect(pixel(bytes, 1, 0), [0, 255, 0, 255],
          reason: 'right column: incremented twice, tester green passes');

      depthView.dispose();
      targetView.dispose();
      depthTex.dispose();
      target.dispose();
      tester.dispose();
      testerModule.dispose();
      writer.dispose();
      writerModule.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('3D texture: per-slice uploads read back by depth coordinate',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      const sliceColors = [
        [255, 0, 0, 255],
        [0, 255, 0, 255],
        [0, 0, 255, 255],
        [255, 255, 0, 255],
      ];
      final tex3d = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
        dimension: GpuTextureDimension.d3,
        depthOrArrayLayers: 4,
      );
      for (var z = 0; z < 4; z++) {
        final data = Uint8List.fromList(
            List.generate(4, (_) => sliceColors[z]).expand((p) => p).toList());
        device.queue.writeTexture(tex3d, data, arrayLayer: z);
      }
      final view3d = tex3d.createView();

      final module = await device.createShaderModule('''
@group(0) @binding(0) var tex: texture_3d<f32>;
$fsTriVs
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  return textureLoad(tex, vec3i(0, 0, i32(pos.x)), 0);
}
''');
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
      final bgl = pipeline.getBindGroupLayout(0);
      final bind = device.createBindGroup(layout: bgl, entries: [
        GpuTextureBinding(binding: 0, view: view3d),
      ]);

      final target = device.createTexture(
        width: 4,
        height: 1,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final targetView = target.createView();
      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: targetView)]);
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bind);
      pass.draw(3);
      pass.end();
      device.queue.submit([encoder.finish()]);

      final bytes = await readbackRgba(device, target);
      for (var x = 0; x < 4; x++) {
        expect(pixel(bytes, x, 0), sliceColors[x],
            reason: 'pixel $x reads 3D slice z=$x');
      }

      targetView.dispose();
      target.dispose();
      bind.dispose();
      bgl.dispose();
      pipeline.dispose();
      module.dispose();
      view3d.dispose();
      tex3d.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('back-face culling rejects clockwise triangles', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final module = await device.createShaderModule('''
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  // Clockwise winding (the fullscreen triangle with two verts swapped).
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(-1.0, 1.0), vec2f(3.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 0.0, 0.0, 1.0); }
''');
      final culled = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        cullMode: GpuCullMode.back,
        frontFace: GpuFrontFace.ccw,
      );
      final unculled = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        cullMode: GpuCullMode.none,
      );

      GpuTexture makeTarget() => device.createTexture(
            width: 2,
            height: 2,
            format: GpuTextureFormat.rgba8Unorm,
            usage:
                GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
          );
      final t0 = makeTarget();
      final t1 = makeTarget();
      final v0 = t0.createView();
      final v1 = t1.createView();
      final encoder = device.createCommandEncoder();
      encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: v0)])
        ..setPipeline(culled)
        ..draw(3)
        ..end();
      encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: v1)])
        ..setPipeline(unculled)
        ..draw(3)
        ..end();
      device.queue.submit([encoder.finish()]);

      expect(pixel(await readbackRgba(device, t0), 0, 0), [0, 0, 0, 255],
          reason: 'CW triangle culled with cullMode back + frontFace ccw');
      expect(pixel(await readbackRgba(device, t1), 0, 0), [255, 0, 0, 255],
          reason: 'same triangle draws with cullMode none');

      v1.dispose();
      v0.dispose();
      t1.dispose();
      t0.dispose();
      unculled.dispose();
      culled.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('point-list topology rasterizes a single pixel', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final module = await device.createShaderModule('''
@vertex
fn vs_main() -> @builtin(position) vec4f {
  // Center of pixel (1, 1) in a 2x2 target.
  return vec4f(0.5, -0.5, 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(0.0, 1.0, 1.0, 1.0); }
''');
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        topology: GpuPrimitiveTopology.pointList,
      );
      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final view = target.createView();
      final encoder = device.createCommandEncoder();
      encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: view)])
        ..setPipeline(pipeline)
        ..draw(1)
        ..end();
      device.queue.submit([encoder.finish()]);

      final bytes = await readbackRgba(device, target);
      expect(pixel(bytes, 1, 1), [0, 255, 255, 255], reason: 'the point');
      expect(pixel(bytes, 0, 0), [0, 0, 0, 255], reason: 'everything else');

      view.dispose();
      target.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test(
        'shadow mapping: depth pass + comparison sampler + depth bias '
        'shade the occluded half', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      // Depth pass: a left-half quad at z=0.3 into a sampleable depth map.
      final casterModule = await device.createShaderModule('''
@vertex
fn vs_main(@location(0) pos: vec3f) -> @builtin(position) vec4f {
  return vec4f(pos, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(0.0); }
''');
      final caster = await device.createRenderPipeline(
        module: casterModule,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        depthFormat: GpuTextureFormat.depth32Float,
        depthCompare: GpuCompareFunction.always,
        depthBias: 2,
        vertexBuffers: [
          GpuVertexLayout(arrayStride: 12, attributes: const [
            GpuVertexAttr(
                format: GpuVertexFormat.float32x3,
                offset: 0,
                shaderLocation: 0),
          ]),
        ],
      );
      final leftQuad = Float32List.fromList([
        -1, -1, 0.3, 0, -1, 0.3, -1, 1, 0.3, //
        -1, 1, 0.3, 0, -1, 0.3, 0, 1, 0.3, //
      ]);
      final vbuf = device.createBuffer(
          size: leftQuad.lengthInBytes,
          usage: GpuBufferUsage.vertex | GpuBufferUsage.copyDst);
      device.queue.writeBuffer(vbuf, leftQuad.buffer.asUint8List());

      final shadowMap = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.depth32Float,
        usage:
            GpuTextureUsage.renderAttachment | GpuTextureUsage.textureBinding,
      );
      final shadowView = shadowMap.createView();
      final dummy = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment,
      );
      final dummyView = dummy.createView();

      // Lit pass: comparison-sample the shadow map (ref 0.5, compare less).
      final litModule = await device.createShaderModule('''
@group(0) @binding(0) var shadowSampler: sampler_comparison;
@group(0) @binding(1) var shadowMap: texture_depth_2d;
$fsTriVs
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let uv = pos.xy / 2.0;
  let lit =
      textureSampleCompareLevel(shadowMap, shadowSampler, uv, 0.5);
  return vec4f(lit, lit, lit, 1.0);
}
''');
      final bgl = device.createBindGroupLayout(entries: const [
        GpuLayoutEntry(
            binding: 0,
            visibility: GpuShaderStage.fragment,
            type: GpuBindingType.sampler,
            samplerType: GpuSamplerBindingType.comparison),
        GpuLayoutEntry(
            binding: 1,
            visibility: GpuShaderStage.fragment,
            type: GpuBindingType.texture,
            sampleType: GpuTextureSampleType.depth),
      ]);
      final layout = device.createPipelineLayout(layouts: [bgl]);
      final lit = await device.createRenderPipeline(
          module: litModule,
          targetFormat: GpuTextureFormat.rgba8Unorm,
          layout: layout);
      final cmpSampler = device.createSampler(
        magFilter: GpuFilterMode.nearest,
        minFilter: GpuFilterMode.nearest,
        compare: GpuCompareFunction.less,
      );
      final bind = device.createBindGroup(layout: bgl, entries: [
        GpuSamplerBinding(binding: 0, sampler: cmpSampler),
        GpuTextureBinding(binding: 1, view: shadowView),
      ]);

      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final targetView = target.createView();

      final encoder = device.createCommandEncoder();
      final depthPass = encoder.beginRenderPass(
        colorAttachments: [GpuColorAttachmentInfo(view: dummyView)],
        depthAttachment: GpuDepthAttachmentInfo(
            view: shadowView, storeOp: GpuStoreOp.store),
      );
      depthPass.setPipeline(caster);
      depthPass.setVertexBuffer(0, vbuf);
      depthPass.draw(6);
      depthPass.end();

      final litPass = encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: targetView)]);
      litPass.setPipeline(lit);
      litPass.setBindGroup(0, bind);
      litPass.draw(3);
      litPass.end();
      device.queue.submit([encoder.finish()]);

      final bytes = await readbackRgba(device, target);
      expect(pixel(bytes, 0, 0), [0, 0, 0, 255],
          reason: 'left: occluder at 0.3 < ref 0.5 fails compare → shadow');
      expect(pixel(bytes, 1, 0), [255, 255, 255, 255],
          reason: 'right: cleared depth 1.0 passes ref 0.5 → lit');

      targetView.dispose();
      target.dispose();
      bind.dispose();
      cmpSampler.dispose();
      lit.dispose();
      layout.dispose();
      bgl.dispose();
      litModule.dispose();
      dummyView.dispose();
      dummy.dispose();
      shadowView.dispose();
      shadowMap.dispose();
      vbuf.dispose();
      caster.dispose();
      casterModule.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('custom blend state and color write mask', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final greenModule = await device.createShaderModule('''
$fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(0.0, 1.0, 0.0, 1.0); }
''');
      final whiteModule = await device.createShaderModule('''
$fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 1.0, 1.0, 1.0); }
''');
      // (one, one) additive via the custom-blend path.
      final additive = await device.createRenderPipeline(
        module: greenModule,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        blendState: const GpuBlendState(
            colorSrc: GpuBlendFactor.one, colorDst: GpuBlendFactor.one),
      );
      // White draw that may only touch the green channel.
      final maskedWrite = await device.createRenderPipeline(
        module: whiteModule,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        colorWriteMask: GpuColorWriteMask.green,
      );

      GpuTexture makeTarget() => device.createTexture(
            width: 2,
            height: 2,
            format: GpuTextureFormat.rgba8Unorm,
            usage:
                GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
          );
      final t0 = makeTarget();
      final t1 = makeTarget();
      final v0 = t0.createView();
      final v1 = t1.createView();
      final encoder = device.createCommandEncoder();
      encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(view: v0, clearColor: const GpuColor(1, 0, 0))
      ])
        ..setPipeline(additive)
        ..draw(3)
        ..end();
      encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: v1)])
        ..setPipeline(maskedWrite)
        ..draw(3)
        ..end();
      device.queue.submit([encoder.finish()]);

      expect(pixel(await readbackRgba(device, t0), 0, 0), [255, 255, 0, 255],
          reason: 'green + red clear via custom (one, one) add = yellow');
      expect(pixel(await readbackRgba(device, t1), 0, 0), [0, 255, 0, 255],
          reason: 'white through a green-only write mask');

      v1.dispose();
      v0.dispose();
      t1.dispose();
      t0.dispose();
      maskedWrite.dispose();
      additive.dispose();
      whiteModule.dispose();
      greenModule.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('feature enumeration round-trips through requestDevice', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final supported = adapter.features;
      expect(supported, isNotEmpty);
      expect(supported.contains(GpuFeature.timestampQuery),
          adapter.supportsTimestampQueries);

      // Request one optional feature the adapter actually has.
      const candidates = [
        GpuFeature.float32Filterable,
        GpuFeature.depthClipControl,
        GpuFeature.indirectFirstInstance,
        GpuFeature.shaderF16,
      ];
      final pick = candidates.where(supported.contains).toList();
      final device =
          await adapter.requestDevice(requiredFeatures: pick.toSet());
      for (final f in pick) {
        expect(device.features, contains(f),
            reason: 'requested feature $f is active on the device');
      }
      device.dispose();
      adapter.dispose();
    });

    test('copy origins select texture sub-regions', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      // 4x4 source where every texel is unique: r = x*40, g = y*40.
      final src = device.createTexture(
        width: 4,
        height: 4,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.copyDst | GpuTextureUsage.copySrc,
      );
      final data = Uint8List(4 * 4 * 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final i = (y * 4 + x) * 4;
          data[i] = x * 40;
          data[i + 1] = y * 40;
          data[i + 2] = 200;
          data[i + 3] = 255;
        }
      }
      device.queue.writeTexture(src, data);

      final dst = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.copyDst | GpuTextureUsage.copySrc,
      );
      final encoder = device.createCommandEncoder();
      encoder.copyTextureToTexture(src, dst,
          width: 2, height: 2, srcX: 2, srcY: 2);
      device.queue.submit([encoder.finish()]);

      // Overwrite dst texel (1,1) through a writeTexture origin.
      device.queue.writeTexture(
          dst, Uint8List.fromList([0, 0, 255, 255]),
          originX: 1, originY: 1, width: 1, height: 1);

      final bytes = await readbackRgba(device, dst);
      expect(pixel(bytes, 0, 0), [80, 80, 200, 255],
          reason: 'dst(0,0) = src(2,2)');
      expect(pixel(bytes, 1, 0), [120, 80, 200, 255],
          reason: 'dst(1,0) = src(3,2)');
      expect(pixel(bytes, 0, 1), [80, 120, 200, 255],
          reason: 'dst(0,1) = src(2,3)');
      expect(pixel(bytes, 1, 1), [0, 0, 255, 255],
          reason: 'origin-targeted writeTexture');

      dst.dispose();
      src.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('mappedAtCreation + mapWrite + clearBuffer round-trip', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      // Path 1: mappedAtCreation → writeMapped (zero-copy) → unmap.
      final created = device.createBuffer(
          size: 16,
          // clearBuffer needs copyDst.
          usage: GpuBufferUsage.copySrc | GpuBufferUsage.copyDst,
          mappedAtCreation: true);
      created
          .writeMapped(Float32List.fromList([1, 2, 3, 4]).buffer.asUint8List());
      created.unmap();

      final staging = device.createBuffer(
          size: 16, usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      var encoder = device.createCommandEncoder();
      encoder.clearBuffer(created, offset: 4, size: 8);
      encoder.copyBufferToBuffer(created, staging);
      device.queue.submit([encoder.finish()]);
      var bytes = await staging.mapRead();
      expect(bytes.buffer.asFloat32List(bytes.offsetInBytes, 4), [1, 0, 0, 4],
          reason: 'writeMapped upload with the middle cleared');

      // Path 2: re-map an existing MAP_WRITE buffer.
      final mappable = device.createBuffer(
          size: 16, usage: GpuBufferUsage.mapWrite | GpuBufferUsage.copySrc);
      await mappable.mapWrite();
      mappable.writeMapped(
          Float32List.fromList([9, 8, 7, 6]).buffer.asUint8List());
      mappable.unmap();
      encoder = device.createCommandEncoder();
      encoder.copyBufferToBuffer(mappable, staging);
      device.queue.submit([encoder.finish()]);
      bytes = await staging.mapRead();
      expect(bytes.buffer.asFloat32List(bytes.offsetInBytes, 4), [9, 8, 7, 6],
          reason: 'mapWrite upload');

      mappable.dispose();
      staging.dispose();
      created.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('compilation info, debug markers, and encoder timestamps', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final hasTs = adapter.supportsTimestampQueries;
      final device =
          await adapter.requestDevice(requireTimestampQueries: hasTs);

      final module = await device.createShaderModule('''
$fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(1.0); }
''');
      final messages = await module.getCompilationInfo();
      expect(messages.where((m) => m.type == 1), isEmpty,
          reason: 'a valid module has no error diagnostics');

      // Debug groups/markers everywhere + an encoder-level timestamp; the
      // proof is that validation stays clean end-to-end.
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
      final computeModule = await device.createShaderModule('''
@compute @workgroup_size(1)
fn main() {}
''');
      final computePipeline =
          await device.createComputePipeline(module: computeModule);
      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment,
      );
      final view = target.createView();
      final querySet = hasTs ? await device.createTimestampQuerySet(2) : null;

      device.pushErrorScope(GpuErrorFilter.validation);
      final encoder = device.createCommandEncoder();
      encoder.pushDebugGroup('frame');
      if (querySet != null) encoder.writeTimestamp(querySet, 0);
      final computePass = encoder.beginComputePass();
      computePass.pushDebugGroup('sim');
      computePass.setPipeline(computePipeline);
      computePass.dispatchWorkgroups(1);
      computePass.insertDebugMarker('dispatched');
      computePass.popDebugGroup();
      computePass.end();
      final pass = encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: view)]);
      pass.pushDebugGroup('draw');
      pass.setPipeline(pipeline);
      pass.draw(3);
      pass.insertDebugMarker('drawn');
      pass.popDebugGroup();
      pass.end();
      if (querySet != null) encoder.writeTimestamp(querySet, 1);
      encoder.insertDebugMarker('frame-done');
      encoder.popDebugGroup();
      device.queue.submit([encoder.finish()]);
      final error = await device.popErrorScope();
      expect(error, isNull, reason: 'debug/timestamp commands validate');

      querySet?.dispose();
      view.dispose();
      target.dispose();
      computePipeline.dispose();
      computeModule.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('alpha-to-coverage discards zero-alpha fragments', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final module = await device.createShaderModule('''
$fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 1.0, 1.0, 0.0); }
''');
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        sampleCount: 4,
        alphaToCoverage: true,
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
      final encoder = device.createCommandEncoder();
      encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(view: msaaView, resolveTarget: resolveView)
      ])
        ..setPipeline(pipeline)
        ..draw(3)
        ..end();
      device.queue.submit([encoder.finish()]);

      expect(pixel(await readbackRgba(device, resolve), 0, 0), [0, 0, 0, 255],
          reason: 'alpha 0 → zero coverage → clear color survives');

      resolveView.dispose();
      msaaView.dispose();
      resolve.dispose();
      msaa.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('srgb view reinterprets a linear texture', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final tex = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
        viewFormat: GpuTextureFormat.rgba8UnormSrgb,
      );
      final srgbView =
          tex.createView(format: GpuTextureFormat.rgba8UnormSrgb);
      final encoder = device.createCommandEncoder();
      encoder.beginRenderPass(colorAttachments: [
        GpuColorAttachmentInfo(
            view: srgbView, clearColor: const GpuColor(0.5, 0.5, 0.5))
      ]).end();
      device.queue.submit([encoder.finish()]);

      // Linear 0.5 sRGB-encodes to ~0.7354 → ~188 in the raw unorm bytes.
      final bytes = await readbackRgba(device, tex);
      expect(pixel(bytes, 0, 0)[0], inInclusiveRange(186, 190),
          reason: 'raw bytes hold the sRGB-encoded value');

      srgbView.dispose();
      tex.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('read-only depth attachment still depth-tests draws', () async {
      if (Platform.isWindows) {
        // wgpu-native v29 D3D12 aborts the process on a read-only depth
        // attachment under WARP — CI-verified to crash in isolation, while
        // the same test passes on Metal and Vulkan/lavapipe. Upstream
        // backend issue; revisit on a real-GPU Windows box or the next
        // wgpu-native release.
        markTestSkipped('read-only depth aborts wgpu D3D12/WARP (upstream)');
        return;
      }
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final depthTex = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.depth24Plus,
        usage: GpuTextureUsage.renderAttachment,
      );
      final depthView = depthTex.createView();
      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final targetView = target.createView();

      final module = await device.createShaderModule('''
@vertex
fn vs_main(@builtin(vertex_index) i: u32, @builtin(instance_index) z: u32)
    -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  // Instance 0 draws at z=0.3 (passes vs 0.4), instance 1 at z=0.5 (fails).
  return vec4f(pos[i], select(0.5, 0.3, z == 0u), 1.0);
}
struct FOut { @location(0) color: vec4f };
@fragment
fn fs_main(@builtin(position) p: vec4f) -> FOut {
  var o: FOut;
  o.color = vec4f(0.0, 1.0, 0.0, 1.0);
  return o;
}
''');
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        depthFormat: GpuTextureFormat.depth24Plus,
        depthWriteEnabled: false,
        depthCompare: GpuCompareFunction.less,
      );

      final encoder = device.createCommandEncoder();
      // Pass 1: initialize depth to 0.4 (clear only, stored).
      encoder
          .beginRenderPass(
            colorAttachments: [GpuColorAttachmentInfo(view: targetView)],
            depthAttachment: GpuDepthAttachmentInfo(
                view: depthView, clearValue: 0.4, storeOp: GpuStoreOp.store),
          )
          .end();
      // Pass 2: read-only depth; z=0.3 passes, z=0.5 is rejected.
      final pass = encoder.beginRenderPass(
        colorAttachments: [
          GpuColorAttachmentInfo(view: targetView, loadOp: GpuLoadOp.load)
        ],
        depthAttachment:
            GpuDepthAttachmentInfo(view: depthView, depthReadOnly: true),
      );
      pass.setPipeline(pipeline);
      pass.draw(3, instanceCount: 1, firstInstance: 0); // z=0.3 → green
      pass.end();
      // Pass 3: same read-only depth, occluded draw must not appear.
      final pass3 = encoder.beginRenderPass(
        colorAttachments: [
          GpuColorAttachmentInfo(view: targetView, loadOp: GpuLoadOp.load)
        ],
        depthAttachment:
            GpuDepthAttachmentInfo(view: depthView, depthReadOnly: true),
      );
      pass3.setPipeline(pipeline);
      pass3.draw(3, instanceCount: 1, firstInstance: 1); // z=0.5 → rejected
      pass3.end();
      device.queue.submit([encoder.finish()]);

      expect(pixel(await readbackRgba(device, target), 0, 0),
          [0, 255, 0, 255],
          reason: 'near draw passed the read-only depth test and survived');

      targetView.dispose();
      depthView.dispose();
      target.dispose();
      depthTex.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('stencil write mask and per-face state', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final redModule = await device.createShaderModule('''
$fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 0.0, 0.0, 1.0); }
''');
      final greenModule = await device.createShaderModule('''
$fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(0.0, 1.0, 0.0, 1.0); }
''');
      // Writer replaces stencil with the reference — but the write mask is
      // 0, so nothing actually lands.
      final maskedWriter = await device.createRenderPipeline(
        module: redModule,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        depthFormat: GpuTextureFormat.depth24PlusStencil8,
        depthWriteEnabled: false,
        depthCompare: GpuCompareFunction.always,
        stencilPassOp: GpuStencilOperation.replace,
        stencilWriteMask: 0,
      );
      // Tester passes only where stencil == 1.
      final tester = await device.createRenderPipeline(
        module: greenModule,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        depthFormat: GpuTextureFormat.depth24PlusStencil8,
        depthWriteEnabled: false,
        depthCompare: GpuCompareFunction.always,
        stencilCompare: GpuCompareFunction.equal,
        // Distinct back-face state compiles and applies (front is used
        // here since the fullscreen triangle is CCW).
        stencilBack: const GpuStencilFace(compare: GpuCompareFunction.never),
      );

      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final depthTex = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.depth24PlusStencil8,
        usage: GpuTextureUsage.renderAttachment,
      );
      final targetView = target.createView();
      final depthView = depthTex.createView();

      final encoder = device.createCommandEncoder();
      final pass = encoder.beginRenderPass(
        colorAttachments: [GpuColorAttachmentInfo(view: targetView)],
        depthAttachment: GpuDepthAttachmentInfo(
          view: depthView,
          stencilLoadOp: GpuLoadOp.clear,
          stencilStoreOp: GpuStoreOp.discard,
        ),
      );
      pass.setStencilReference(1);
      pass.setPipeline(maskedWriter);
      pass.draw(3); // red everywhere, stencil write masked out
      pass.setPipeline(tester);
      pass.draw(3); // equal-1 fails everywhere (stencil stayed 0)
      pass.end();
      device.queue.submit([encoder.finish()]);

      expect(pixel(await readbackRgba(device, target), 0, 0),
          [255, 0, 0, 255],
          reason: 'write mask 0 kept stencil at 0, so the tester was masked');

      depthView.dispose();
      targetView.dispose();
      depthTex.dispose();
      target.dispose();
      tester.dispose();
      maskedWriter.dispose();
      greenModule.dispose();
      redModule.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('bundle indirect draw executes GPU-authored args', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final module = await device.createShaderModule('''
$fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 0.0, 1.0, 1.0); }
''');
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
      final args = device.createBuffer(
          size: 16, usage: GpuBufferUsage.indirect | GpuBufferUsage.copyDst);
      device.queue.writeBuffer(
          args, Uint32List.fromList([3, 1, 0, 0]).buffer.asUint8List());

      final bundleEncoder = device.createRenderBundleEncoder(
          colorFormats: [GpuTextureFormat.rgba8Unorm]);
      bundleEncoder.setPipeline(pipeline);
      bundleEncoder.drawIndirect(args);
      final bundle = bundleEncoder.finish();

      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final view = target.createView();
      final encoder = device.createCommandEncoder();
      encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: view)])
        ..executeBundle(bundle)
        ..end();
      device.queue.submit([encoder.finish()]);

      expect(pixel(await readbackRgba(device, target), 0, 0),
          [255, 0, 255, 255]);

      view.dispose();
      target.dispose();
      bundle.dispose();
      args.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('full limits surface is populated', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice(
        requiredLimits: const GpuRequiredLimits(maxVertexAttributes: 8),
      );
      final limits = device.limits;
      expect(limits.maxVertexAttributes, 8,
          reason: 'newly exposed limit override applies');
      expect(limits.maxColorAttachments, greaterThanOrEqualTo(4));
      expect(limits.maxVertexBuffers, greaterThan(0));
      expect(limits.maxSampledTexturesPerShaderStage, greaterThan(0));
      expect(limits.maxComputeWorkgroupsPerDimension, greaterThan(0));
      device.dispose();
      adapter.dispose();
    });

    test('introspection getters report creation-time state', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final plain = device.createBuffer(
          size: 32, usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      expect(plain.usage, GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      expect(plain.mapState, GpuBufferMapState.unmapped);

      final premapped = device.createBuffer(
          size: 16,
          usage: GpuBufferUsage.mapWrite | GpuBufferUsage.copySrc,
          mappedAtCreation: true);
      expect(premapped.mapState, GpuBufferMapState.mapped);
      premapped.writeMapped(Uint8List(16));
      premapped.unmap();
      expect(premapped.mapState, GpuBufferMapState.unmapped);
      await premapped.mapWrite();
      expect(premapped.mapState, GpuBufferMapState.mapped);
      premapped.unmap();

      final tex = device.createTexture(
        width: 8,
        height: 4,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
        mipLevelCount: 2,
        depthOrArrayLayers: 2,
      );
      expect(tex.width, 8);
      expect(tex.height, 4);
      expect(tex.mipLevelCount, 2);
      expect(tex.sampleCount, 1);
      expect(tex.depthOrArrayLayers, 2);
      expect(tex.dimension, GpuTextureDimension.d2);
      expect(tex.usage,
          GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst);

      final occlusion = await device.createOcclusionQuerySet(5);
      expect(occlusion.count, 5);
      expect(occlusion.type, GpuQueryType.occlusion);
      if (adapter.supportsTimestampQueries) {
        final tsDevice =
            await adapter.requestDevice(requireTimestampQueries: true);
        final ts = await tsDevice.createTimestampQuerySet(3);
        expect(ts.type, GpuQueryType.timestamp);
        ts.dispose();
        tsDevice.dispose();
      }

      occlusion.dispose();
      tex.dispose();
      premapped.dispose();
      plain.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('BC1 compressed texture uploads and samples (feature-gated)',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      if (!adapter.features.contains(GpuFeature.textureCompressionBc)) {
        adapter.dispose();
        markTestSkipped('adapter lacks texture-compression-bc');
        return;
      }
      final device = await adapter.requestDevice(
          requiredFeatures: {GpuFeature.textureCompressionBc});

      // One solid-red BC1 block: color0 = color1 = 0xF800 (red in 565),
      // all 2-bit indices 0 → every texel decodes to pure red.
      final bc1 = device.createTexture(
        width: 4,
        height: 4,
        format: GpuTextureFormat.bc1RgbaUnorm,
        usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
      );
      device.queue.writeTexture(
        bc1,
        Uint8List.fromList([0x00, 0xF8, 0x00, 0xF8, 0, 0, 0, 0]),
        bytesPerRow: 8, // one 4-wide block row
      );

      final module = await device.createShaderModule('''
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;
$fsTriVs
@fragment
fn fs_main() -> @location(0) vec4f {
  return textureSample(tex, samp, vec2f(0.5, 0.5));
}
''');
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
      final sampler = device.createSampler(
          magFilter: GpuFilterMode.nearest, minFilter: GpuFilterMode.nearest);
      final view = bc1.createView();
      final bgl = pipeline.getBindGroupLayout(0);
      final bind = device.createBindGroup(layout: bgl, entries: [
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
      final encoder = device.createCommandEncoder();
      encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: targetView)])
        ..setPipeline(pipeline)
        ..setBindGroup(0, bind)
        ..draw(3)
        ..end();
      device.queue.submit([encoder.finish()]);

      expect(pixel(await readbackRgba(device, target), 0, 0),
          [255, 0, 0, 255],
          reason: 'BC1 block decodes to solid red');

      targetView.dispose();
      target.dispose();
      bind.dispose();
      bgl.dispose();
      view.dispose();
      sampler.dispose();
      pipeline.dispose();
      module.dispose();
      bc1.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('format info exposes correct block-size math', () {
      // Uncompressed: 1×1 blocks, byte size per texel.
      expect(GpuTextureFormat.rgba8Unorm.isCompressed, isFalse);
      expect(GpuTextureFormat.rgba8Unorm.bytesPerRowFor(3), 12);
      expect(GpuTextureFormat.r8Unorm.bytesPerBlock, 1);
      expect(GpuTextureFormat.rgba16Float.bytesPerRowFor(4), 32);
      expect(GpuTextureFormat.rgba32Float.byteLengthFor(2, 2), 64);
      expect(GpuTextureFormat.depth32Float.bytesPerBlock, 4);
      // BC1: 4×4 blocks, 8 bytes each; width rounds up to whole blocks.
      expect(GpuTextureFormat.bc1RgbaUnorm.isCompressed, isTrue);
      expect(GpuTextureFormat.bc1RgbaUnorm.blockWidth, 4);
      expect(GpuTextureFormat.bc1RgbaUnorm.bytesPerRowFor(8), 16);
      expect(GpuTextureFormat.bc1RgbaUnorm.bytesPerRowFor(5), 16);
      expect(GpuTextureFormat.bc1RgbaUnorm.byteLengthFor(8, 8), 32);
      // 16-byte 4×4 blocks.
      expect(GpuTextureFormat.bc7RgbaUnorm.byteLengthFor(4, 4), 16);
      expect(GpuTextureFormat.etc2Rgba8Unorm.bytesPerBlock, 16);
      expect(GpuTextureFormat.etc2Rgb8Unorm.bytesPerBlock, 8);
      expect(GpuTextureFormat.eacR11Unorm.bytesPerBlock, 8);
      expect(GpuTextureFormat.astc4x4Unorm.byteLengthFor(8, 8), 64);
      // ASTC 8×8: 16-byte blocks covering 8×8 texels.
      expect(GpuTextureFormat.astc8x8Unorm.blockWidth, 8);
      expect(GpuTextureFormat.astc8x8Unorm.bytesPerRowFor(16), 32);
      expect(GpuTextureFormat.astc8x8Unorm.byteLengthFor(16, 16), 64);
      // depth24Plus has no fixed copy footprint.
      expect(() => GpuTextureFormat.depth24Plus.bytesPerRowFor(4),
          throwsStateError);
    });

    test('compressed upload computes stride automatically (BC1 quadrants)',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      if (!adapter.features.contains(GpuFeature.textureCompressionBc)) {
        adapter.dispose();
        markTestSkipped('adapter lacks texture-compression-bc');
        return;
      }
      final device = await adapter.requestDevice(
          requiredFeatures: {GpuFeature.textureCompressionBc});

      // 8×8 BC1 = 2×2 blocks. Each block is solid: color0 = color1 = the
      // RGB565 color, all indices 0. Row stride (16 bytes) is NOT passed —
      // writeTexture must derive it from the format info.
      List<int> solidBlock(int c565) =>
          [c565 & 0xFF, c565 >> 8, c565 & 0xFF, c565 >> 8, 0, 0, 0, 0];
      final data = Uint8List.fromList([
        ...solidBlock(0xF800), ...solidBlock(0x07E0), // red | green
        ...solidBlock(0x001F), ...solidBlock(0xFFFF), // blue | white
      ]);
      final bc1 = device.createTexture(
        width: 8,
        height: 8,
        format: GpuTextureFormat.bc1RgbaUnorm,
        usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
      );

      // Layout validation fires before any native call.
      expect(() => device.queue.writeTexture(bc1, Uint8List(16)),
          throwsArgumentError, reason: '16 bytes < the 32 the copy needs');
      expect(() => device.queue.writeTexture(bc1, data, originX: 2),
          throwsArgumentError, reason: 'origin not block-aligned');

      device.queue.writeTexture(bc1, data);

      final module = await device.createShaderModule('''
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;
$fsTriVs
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  return textureSample(tex, samp, pos.xy / 2.0);
}
''');
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
      final sampler = device.createSampler(
          magFilter: GpuFilterMode.nearest, minFilter: GpuFilterMode.nearest);
      final view = bc1.createView();
      final bgl = pipeline.getBindGroupLayout(0);
      final bind = device.createBindGroup(layout: bgl, entries: [
        GpuSamplerBinding(binding: 0, sampler: sampler),
        GpuTextureBinding(binding: 1, view: view),
      ]);

      // A 2×2 target samples one texel from the middle of each block.
      final target = device.createTexture(
        width: 2,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final targetView = target.createView();
      final encoder = device.createCommandEncoder();
      encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: targetView)])
        ..setPipeline(pipeline)
        ..setBindGroup(0, bind)
        ..draw(3)
        ..end();
      device.queue.submit([encoder.finish()]);

      final bytes = await readbackRgba(device, target);
      expect(pixel(bytes, 0, 0), [255, 0, 0, 255], reason: 'top-left red');
      expect(pixel(bytes, 1, 0), [0, 255, 0, 255], reason: 'top-right green');
      expect(pixel(bytes, 0, 1), [0, 0, 255, 255], reason: 'bottom-left blue');
      expect(pixel(bytes, 1, 1), [255, 255, 255, 255],
          reason: 'bottom-right white');

      targetView.dispose();
      target.dispose();
      bind.dispose();
      bgl.dispose();
      view.dispose();
      sampler.dispose();
      pipeline.dispose();
      module.dispose();
      bc1.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('non-4-byte format gets a tight default stride (r8Unorm)', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      // 4×2 r8 texture, tightly packed 8 bytes — the default stride must be
      // 4 (w × 1 byte), not the old rgba-assuming w × 4.
      final tex = device.createTexture(
        width: 4,
        height: 2,
        format: GpuTextureFormat.r8Unorm,
        usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
      );
      device.queue.writeTexture(
          tex, Uint8List.fromList([10, 20, 30, 40, 50, 60, 70, 80]));

      final module = await device.createShaderModule('''
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;
$fsTriVs
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  return textureSample(tex, samp, pos.xy / vec2f(4.0, 2.0));
}
''');
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
      final sampler = device.createSampler(
          magFilter: GpuFilterMode.nearest, minFilter: GpuFilterMode.nearest);
      final view = tex.createView();
      final bgl = pipeline.getBindGroupLayout(0);
      final bind = device.createBindGroup(layout: bgl, entries: [
        GpuSamplerBinding(binding: 0, sampler: sampler),
        GpuTextureBinding(binding: 1, view: view),
      ]);

      final target = device.createTexture(
        width: 4,
        height: 2,
        format: GpuTextureFormat.rgba8Unorm,
        usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
      );
      final targetView = target.createView();
      final encoder = device.createCommandEncoder();
      encoder.beginRenderPass(
          colorAttachments: [GpuColorAttachmentInfo(view: targetView)])
        ..setPipeline(pipeline)
        ..setBindGroup(0, bind)
        ..draw(3)
        ..end();
      device.queue.submit([encoder.finish()]);

      // Row 1 texels only decode correctly if the upload stride was tight.
      final bytes = await readbackRgba(device, target);
      expect(pixel(bytes, 3, 0)[0], 40, reason: 'row 0 end');
      expect(pixel(bytes, 1, 1)[0], 60, reason: 'row 1 reads bytes 4..7');
      expect(pixel(bytes, 3, 1)[0], 80, reason: 'row 1 end');

      targetView.dispose();
      target.dispose();
      bind.dispose();
      bgl.dispose();
      view.dispose();
      sampler.dispose();
      pipeline.dispose();
      module.dispose();
      tex.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('five color targets render in one pass', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      // rgba8unorm costs 8 bytes/sample as a render target, so 5 targets
      // need 40 > the default 32 limit.
      if (adapter.limits.maxColorAttachmentBytesPerSample < 40) {
        adapter.dispose();
        markTestSkipped('adapter cannot raise maxColorAttachmentBytesPerSample');
        return;
      }
      final device = await adapter.requestDevice(
          requiredLimits:
              const GpuRequiredLimits(maxColorAttachmentBytesPerSample: 40));
      final module = await device.createShaderModule('''
struct FOut {
  @location(0) c0: vec4f,
  @location(1) c1: vec4f,
  @location(2) c2: vec4f,
  @location(3) c3: vec4f,
  @location(4) c4: vec4f,
};
$fsTriVs
@fragment
fn fs_main() -> FOut {
  var o: FOut;
  o.c0 = vec4f(1.0, 0.0, 0.0, 1.0);
  o.c1 = vec4f(0.0, 1.0, 0.0, 1.0);
  o.c2 = vec4f(0.0, 0.0, 1.0, 1.0);
  o.c3 = vec4f(1.0, 1.0, 0.0, 1.0);
  o.c4 = vec4f(0.0, 1.0, 1.0, 1.0);
  return o;
}
''');
      final pipeline = await device.createRenderPipeline(
        module: module,
        targetFormat: GpuTextureFormat.rgba8Unorm,
        extraTargetFormats: List.filled(4, GpuTextureFormat.rgba8Unorm),
      );
      final targets = List.generate(
          5,
          (_) => device.createTexture(
                width: 2,
                height: 2,
                format: GpuTextureFormat.rgba8Unorm,
                usage: GpuTextureUsage.renderAttachment |
                    GpuTextureUsage.copySrc,
              ));
      final views = [for (final t in targets) t.createView()];
      final encoder = device.createCommandEncoder();
      encoder.beginRenderPass(colorAttachments: [
        for (final v in views) GpuColorAttachmentInfo(view: v)
      ])
        ..setPipeline(pipeline)
        ..draw(3)
        ..end();
      device.queue.submit([encoder.finish()]);

      const expected = [
        [255, 0, 0, 255],
        [0, 255, 0, 255],
        [0, 0, 255, 255],
        [255, 255, 0, 255],
        [0, 255, 255, 255],
      ];
      for (var i = 0; i < 5; i++) {
        expect(pixel(await readbackRgba(device, targets[i]), 0, 0),
            expected[i],
            reason: 'target $i');
      }

      for (final v in views) {
        v.dispose();
      }
      for (final t in targets) {
        t.dispose();
      }
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('five dynamic offsets apply in one setBindGroup call', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      final module = await device.createShaderModule('''
@group(0) @binding(0) var<uniform> p0: f32;
@group(0) @binding(1) var<uniform> p1: f32;
@group(0) @binding(2) var<uniform> p2: f32;
@group(0) @binding(3) var<uniform> p3: f32;
@group(0) @binding(4) var<uniform> p4: f32;
@group(0) @binding(5) var<storage, read_write> out: array<f32>;

@compute @workgroup_size(1)
fn main() {
  out[0] = p0 + p1 + p2 + p3 + p4;
}
''');
      final bgl = device.createBindGroupLayout(entries: [
        for (var i = 0; i < 5; i++)
          GpuLayoutEntry(
              binding: i,
              visibility: GpuShaderStage.compute,
              type: GpuBindingType.uniformBuffer,
              hasDynamicOffset: true),
        const GpuLayoutEntry(
            binding: 5,
            visibility: GpuShaderStage.compute,
            type: GpuBindingType.storageBuffer),
      ]);
      final layout = device.createPipelineLayout(layouts: [bgl]);
      final pipeline =
          await device.createComputePipeline(module: module, layout: layout);

      // Slice at offset k*256 holds the float k+1.
      final params = device.createBuffer(
          size: 256 * 5 + 16,
          usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst);
      final data = Uint8List(256 * 5 + 16);
      for (var k = 0; k < 5; k++) {
        data.buffer.asFloat32List(k * 256, 1)[0] = (k + 1).toDouble();
      }
      device.queue.writeBuffer(params, data);
      final result = device.createBuffer(
          size: 16,
          usage: GpuBufferUsage.storage | GpuBufferUsage.copySrc);
      final bind = device.createBindGroup(layout: bgl, entries: [
        for (var i = 0; i < 5; i++)
          GpuBufferBinding(binding: i, buffer: params, size: 16),
        GpuBufferBinding(binding: 5, buffer: result),
      ]);

      final staging = device.createBuffer(
          size: 16, usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      final encoder = device.createCommandEncoder();
      final pass = encoder.beginComputePass();
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bind, dynamicOffsets: [0, 256, 512, 768, 1024]);
      pass.dispatchWorkgroups(1);
      pass.end();
      encoder.copyBufferToBuffer(result, staging);
      device.queue.submit([encoder.finish()]);

      final bytes = await staging.mapRead();
      expect(bytes.buffer.asFloat32List(bytes.offsetInBytes, 1)[0], 15.0,
          reason: '1+2+3+4+5 through five dynamic slices');

      staging.dispose();
      bind.dispose();
      result.dispose();
      params.dispose();
      pipeline.dispose();
      layout.dispose();
      bgl.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('five bind groups drive one pipeline (raised maxBindGroups)',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      if (adapter.limits.maxBindGroups < 5) {
        adapter.dispose();
        markTestSkipped('adapter supports fewer than 5 bind groups');
        return;
      }
      final device = await adapter.requestDevice(
          requiredLimits: const GpuRequiredLimits(maxBindGroups: 5));

      final module = await device.createShaderModule('''
@group(0) @binding(0) var<uniform> p0: f32;
@group(1) @binding(0) var<uniform> p1: f32;
@group(2) @binding(0) var<uniform> p2: f32;
@group(3) @binding(0) var<uniform> p3: f32;
@group(4) @binding(0) var<uniform> p4: f32;
@group(0) @binding(1) var<storage, read_write> out: array<f32>;

@compute @workgroup_size(1)
fn main() {
  out[0] = p0 * p1 * p2 * p3 * p4;
}
''');
      final firstBgl = device.createBindGroupLayout(entries: const [
        GpuLayoutEntry(
            binding: 0,
            visibility: GpuShaderStage.compute,
            type: GpuBindingType.uniformBuffer),
        GpuLayoutEntry(
            binding: 1,
            visibility: GpuShaderStage.compute,
            type: GpuBindingType.storageBuffer),
      ]);
      final uniformBgl = device.createBindGroupLayout(entries: const [
        GpuLayoutEntry(
            binding: 0,
            visibility: GpuShaderStage.compute,
            type: GpuBindingType.uniformBuffer),
      ]);
      final layout = device.createPipelineLayout(
          layouts: [firstBgl, uniformBgl, uniformBgl, uniformBgl, uniformBgl]);
      final pipeline =
          await device.createComputePipeline(module: module, layout: layout);

      final uniforms = List.generate(5, (k) {
        final b = device.createBuffer(
            size: 16,
            usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst);
        device.queue.writeBuffer(
            b, Float32List.fromList([k + 2.0, 0, 0, 0]).buffer.asUint8List());
        return b;
      });
      final result = device.createBuffer(
          size: 16,
          usage: GpuBufferUsage.storage | GpuBufferUsage.copySrc);
      final binds = [
        device.createBindGroup(layout: firstBgl, entries: [
          GpuBufferBinding(binding: 0, buffer: uniforms[0]),
          GpuBufferBinding(binding: 1, buffer: result),
        ]),
        for (var k = 1; k < 5; k++)
          device.createBindGroup(layout: uniformBgl, entries: [
            GpuBufferBinding(binding: 0, buffer: uniforms[k]),
          ]),
      ];

      final staging = device.createBuffer(
          size: 16, usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      final encoder = device.createCommandEncoder();
      final pass = encoder.beginComputePass();
      pass.setPipeline(pipeline);
      for (var g = 0; g < 5; g++) {
        pass.setBindGroup(g, binds[g]);
      }
      pass.dispatchWorkgroups(1);
      pass.end();
      encoder.copyBufferToBuffer(result, staging);
      device.queue.submit([encoder.finish()]);

      final bytes = await staging.mapRead();
      expect(bytes.buffer.asFloat32List(bytes.offsetInBytes, 1)[0], 720.0,
          reason: '2·3·4·5·6 across five bind groups');

      staging.dispose();
      for (final b in binds) {
        b.dispose();
      }
      result.dispose();
      for (final u in uniforms) {
        u.dispose();
      }
      pipeline.dispose();
      layout.dispose();
      uniformBgl.dispose();
      firstBgl.dispose();
      device.dispose();
      adapter.dispose();
    });

    test(
        'frame graph: 6 ping-pong passes in one submit accumulate exactly',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();

      // +32/255 per pass is exact in rgba8unorm, so 6 passes = exactly 192.
      final module = await device.createShaderModule('''
@group(0) @binding(0) var src: texture_2d<f32>;
$fsTriVs
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  return textureLoad(src, vec2i(pos.xy), 0) + vec4f(32.0 / 255.0, 0.0, 0.0, 0.0);
}
''');
      final pipeline = await device.createRenderPipeline(
          module: module, targetFormat: GpuTextureFormat.rgba8Unorm);
      final bgl = pipeline.getBindGroupLayout(0);

      GpuTexture makePingPong() => device.createTexture(
            width: 2,
            height: 2,
            format: GpuTextureFormat.rgba8Unorm,
            usage: GpuTextureUsage.renderAttachment |
                GpuTextureUsage.textureBinding |
                GpuTextureUsage.copySrc,
          );
      final texA = makePingPong();
      final texB = makePingPong();
      final viewA = texA.createView();
      final viewB = texB.createView();
      final bindFromA = device.createBindGroup(
          layout: bgl, entries: [GpuTextureBinding(binding: 0, view: viewA)]);
      final bindFromB = device.createBindGroup(
          layout: bgl, entries: [GpuTextureBinding(binding: 0, view: viewB)]);

      final encoder = device.createCommandEncoder();
      // Initialize A to opaque black.
      encoder
          .beginRenderPass(
              colorAttachments: [GpuColorAttachmentInfo(view: viewA)])
          .end();
      // A→B→A… six times; the result lands back in A.
      for (var i = 0; i < 6; i++) {
        final readsFromA = i.isEven;
        final pass = encoder.beginRenderPass(colorAttachments: [
          GpuColorAttachmentInfo(view: readsFromA ? viewB : viewA)
        ]);
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, readsFromA ? bindFromA : bindFromB);
        pass.draw(3);
        pass.end();
      }
      device.queue.submit([encoder.finish()]);

      final bytes = await readbackRgba(device, texA);
      expect(pixel(bytes, 0, 0), [192, 0, 0, 255],
          reason: '6 exact +32 accumulation steps ordered within one submit');
      expect(pixel(bytes, 1, 1), [192, 0, 0, 255]);

      bindFromB.dispose();
      bindFromA.dispose();
      viewB.dispose();
      viewA.dispose();
      texB.dispose();
      texA.dispose();
      bgl.dispose();
      pipeline.dispose();
      module.dispose();
      device.dispose();
      adapter.dispose();
    });
  });
}
