# nitro_webgpu

**WebGPU for Flutter** — GPU compute and rendering from Dart with one API on
every platform, powered by [wgpu-native](https://github.com/gfx-rs/wgpu-native)
and bound through [Nitro](https://pub.dev/packages/nitro) FFI.

[![integration tests](https://github.com/Shreemanarjun/nitro_webgpu/actions/workflows/integration_test.yml/badge.svg)](https://github.com/Shreemanarjun/nitro_webgpu/actions/workflows/integration_test.yml)

One shared C++ core wraps the standard `webgpu.h` C ABI; shaders are written
once in WGSL (or GLSL) and run on Metal, Vulkan, and D3D12. The Dart surface
is curated — typed descriptors with defaults, `Future`s instead of callbacks,
deterministic `dispose()` with a GC-finalizer safety net, and no `dart:ffi`
types in the public API.

## What the plugin does

### Adapter and device

```dart
final adapter = await Gpu.requestAdapter();          // real hardware preferred
print('${adapter.info.device} on ${adapter.backendType.name}');

final device = await adapter.requestDevice(
  requireTimestampQueries: adapter.supportsTimestampQueries,
  requiredFeatures: {GpuFeature.textureCompressionBc},
  requiredLimits: GpuRequiredLimits(maxColorAttachmentBytesPerSample: 40),
);
```

`requestAdapter` enumerates every adapter and picks real hardware over
software rasterizers, preferring Vulkan/Metal/D3D12 over GL when both exist.
`powerPreference` selects integrated vs discrete GPUs.

### Buffers

```dart
final storage = device.createBuffer(
    size: bytes, usage: GpuBufferUsage.storage | GpuBufferUsage.copySrc);
device.queue.writeBuffer(storage, data);             // zero-copy upload

final staging = device.createBuffer(
    size: bytes, usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
final result = await staging.mapRead();              // GPU → Dart readback
```

### Shaders — WGSL and GLSL, compiled off-thread

```dart
final module = await device.createShaderModule(wgslSource);

final fs = await device.createShaderModuleGlsl(glslSource,
    stage: GpuShaderStage.fragment);                 // Shadertoy content as-is
```

Modules and pipelines compile on a background worker thread — hot-swapping a
live shader never stalls the UI isolate.

### Pipelines and passes

```dart
final compute = await device.createComputePipeline(module: module);

final render = await device.createRenderPipeline(
  module: module,                  // vertex + fragment (or fragmentModule:)
  targetFormat: GpuTextureFormat.rgba8Unorm,
  vertexBuffers: [GpuVertexLayout(arrayStride: 16, attributes: [...])],
);

final encoder = device.createCommandEncoder();
encoder.beginComputePass()
  ..setPipeline(compute)
  ..setBindGroup(0, bind)
  ..dispatchWorkgroups(n)
  ..end();
device.queue.submit([encoder.finish()]);
```

Bind groups come from `pipeline.getBindGroupLayout(0)` (auto layout) or
explicit `createBindGroupLayout` / `createPipelineLayout`. Render passes
support every draw variant (indexed, instanced, indirect), full
depth/stencil/blend state, MSAA + resolve, multiple render targets, render
bundles, scissor/viewport, and occlusion + timestamp queries.

### Textures and samplers

```dart
device.queue.writeTexture(texture, pixels);          // stride derived
device.queue.writeTexture(bc1Texture, bc1Blocks);    // block math automatic
GpuTextureFormat.bc1RgbaUnorm.byteLengthFor(512, 512);
```

2D/3D/cube textures, storage textures, comparison samplers, mipmaps, and
compressed formats (BC1–7, ETC2/EAC, ASTC) with block-aligned strides
computed for you. `copyTextureToBuffer` handles 256-byte row alignment and
mip-sized extents.

### Rendering to the screen

```dart
WebGpuView(
  device: device,
  renderScale: 1.0,                // dynamic resolution knob
  onFrame: (target, elapsed) {
    // record + submit a render pass into target.view
    // create pipelines against target.targetFormat
  },
)
```

Frames are paced drop-latest (a slow frame never queues behind a stale one)
and the first frame is gated so views never flash black.

### Feature detection

```dart
if (await device.supportsCompute()) { ... }
if (await device.supportsVertexStorage()) { ... }
```

Downlevel GL adapters lack some capabilities (see limitations); these cached
probes let one codebase degrade gracefully.

### GPU timing

With `requireTimestampQueries`, timestamp query sets on compute and render
passes report exact per-pass GPU milliseconds.

## Supported platforms

| Platform | Presentation path | Status |
|---|---|---|
| macOS | GPU→GPU Metal blit into IOSurface | ✅ CI-verified on Metal |
| iOS | GPU→GPU Metal blit into IOSurface | ✅ Simulator CI-verified; physical device pending signing |
| Android (Vulkan) | Zero-copy `WGPUSurface` swapchain | ✅ CI emulator + physical 120 Hz device |
| Android (GL-only) | CPU-readback fallback into the Flutter texture | ✅ Verified on GLES-translator emulator |
| Windows | DXGI shared-texture composition (CPU upload for now) | ✅ CI-verified on D3D12 WARP |
| Linux | CPU readback (dmabuf fast path planned) | ✅ CI-verified on Vulkan lavapipe |
| Web | `navigator.gpu` via JS interop | 📐 designed for, not yet built |

## Limitations

- **GL-backend devices are downlevel.** Without Vulkan (old Android
  hardware, GLES-translator emulators), wgpu's GL backend may lack compute
  shaders and vertex-stage storage buffers — feature-detect with
  `supportsCompute()` / `supportsVertexStorage()`. Emulator capabilities can
  even vary between launches; enable Vulkan (`-gpu swiftshader_indirect`, or
  AVD Graphics: Software) for the full, stable feature set.
- **GL-backend Android presents via CPU readback.** wgpu's GL backend cannot
  create an EGL swapchain on a Flutter `SurfaceProducer` window, so the
  presenter automatically switches to the desktop-style readback ring and
  CPU-blits frames into the window (~60 fps at 1080p on an emulator, but not
  zero-copy). Vulkan devices keep the zero-copy swapchain.
- **Desktop Linux defaults to the Vulkan backend only**: wgpu's GL probe
  races the Flutter GTK engine's EGL context. Pass `GpuBackend.gl` in
  `Gpu.ensureInitialized(backends:)` if you need GL.
- **Desktop frames still cross the CPU once.** Windows composites a shared
  DXGI texture (`GpuSurfaceTexture`) — the engine samples it directly with
  zero raster-thread upload — but filling it is one `UpdateSubresource`
  from the readback ring, and Linux presents via the pixel-buffer texture.
  Fully zero-copy needs wgpu-native to expose D3D12/Vulkan handle
  accessors like the Metal trio it already ships; the C ABI has none today
  (upstream request drafted in `docs/upstream/`). When they land, the CPU
  fill becomes a GPU copy with no other changes.
- **No indirect draws/dispatches on the iOS simulator.** The simulator's
  Metal (Apple2-sim family) lacks indirect execution and wgpu aborts at
  submit — the plugin refuses the encode with a catchable error instead.
  Real iOS devices support indirect fully.
- **Web backend is not built yet**; the API deliberately avoids `dart:ffi`
  types so a `navigator.gpu` implementation can share the same surface.
- Upstream wgpu-native gaps (unimplemented stubs, quirks) are catalogued in
  [PARITY.md](PARITY.md); the plugin calls none of the stubbed functions.

## Error handling

Everything surfaces as a typed Dart error — never a native crash:

```dart
try {
  await device.createShaderModule(brokenWgsl);
} on GpuValidationException catch (e) {
  print(e.message);        // naga's full diagnostics, with source spans
}
```

- **Checked creates**: shader modules and pipelines validate on creation and
  throw `GpuValidationException` carrying the complete naga/WGSL compiler
  message.
- **Error scopes**: `device.pushErrorScope(GpuErrorFilter.validation)` /
  `await device.popErrorScope()` capture errors from any span of commands
  (filters: `validation`, `outOfMemory`, `internal`).
- **Uncaptured errors**: `device.onUncapturedError` is a broadcast stream of
  everything not caught by a scope.
- **Device loss**: `device.onLost` reports the reason
  (`GpuDeviceLostReason`) if the device dies.
- **Native panic guards**: known wgpu-native abort paths (unbalanced
  `popErrorScope`, surface configure on GL, invalid mid-frame surface drops)
  are guarded in the plugin so mistakes stay catchable Dart exceptions
  instead of killing the process.
- **Presentation failures degrade visibly, not fatally**: if a presenter
  cannot be created, `WebGpuView` renders an explanatory message and the app
  keeps running.
- **Argument validation**: byte-length and alignment mistakes (e.g.
  `writeBuffer` sizes not multiple-of-4) throw `ArgumentError` before
  touching the GPU.
