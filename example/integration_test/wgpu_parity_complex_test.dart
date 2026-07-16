// Complex parity checks: each test combines several WebGPU features the way
// a real renderer would (GPU-driven draws, deferred shading, frame graphs),
// so regressions in feature *interactions* surface even when the isolated
// feature tests stay green.
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
