# nitro_webgpu

WebGPU for Flutter, powered by [wgpu-native](https://github.com/gfx-rs/wgpu-native)
and bound through [Nitro](https://pub.dev/packages/nitro) FFI.

One shared C++ implementation (`src/HybridNitroWebgpu.cpp`) wraps the standard
`webgpu.h` C ABI on all five native platforms (iOS, Android, macOS, Windows,
Linux). The public Dart API is a curated, Dart-idiomatic layer — not a 1:1
binding of the WebGPU C API — with deterministic `dispose()` everywhere and a
GC `Finalizer` safety net behind it.

## What it gives you

- **Modern GPU compute and rendering from Dart.** Write WGSL once, run it on
  Metal, Vulkan, and D3D12 through one Dart API — no per-platform graphics
  code, no platform channels in the hot path.
- **A Dart API that feels like Dart.** Typed descriptors with sensible
  defaults instead of C structs, `Future`s instead of callbacks, typed
  exceptions that carry the full naga/WGSL compiler message (with source
  spans), deterministic `dispose()` with a GC finalizer as backstop, and no
  `dart:ffi` types in the public surface — the same API can later be backed
  by `navigator.gpu` on web.
- **Performance as a default, not an option.** Zero-copy buffer and texture
  uploads straight from Dart memory; zero-copy presentation on Android
  (frames render directly into a real `WGPUSurface` swapchain on the Flutter
  texture); a single GPU→GPU Metal blit on Apple platforms; drop-latest frame
  pacing; a `renderScale` knob for dynamic resolution; verified at 120 Hz on
  a 120 Hz device.
- **No UI jank from shader compiles.** Shader modules and pipelines are
  created on a background thread — hot-swapping a live shader doesn't stall
  the raster thread.
- **Real GPU timing.** Timestamp queries on compute and render passes give
  you exact per-pass GPU milliseconds, not frame-time guesses.

## What works today

Verified by **73 integration tests** on macOS (Metal), the iOS simulator,
the Android emulator, and a physical 120 Hz Android device:

- **Core**: adapter/device acquisition with the full 31-field
  `requiredLimits`/`limits` set, feature enumeration + `requiredFeatures`
  (all 22 standard features), error scopes, uncaptured-error stream, checked
  creates that surface WGSL/naga errors as typed Dart exceptions.
- **Compute**: pipelines (auto or explicit layout), dispatch (direct +
  indirect), storage buffers/textures, dynamic bind-group offsets.
- **Rendering**: full primitive state (topology, cull mode, front face),
  vertex/index buffers (40 vertex formats), instancing, every draw variant
  (indexed/indirect/indexed-indirect — in passes and bundles), depth testing
  + depth bias, full stencil state (independent front/back faces, read/write
  masks, references), blend presets plus arbitrary custom blend states and
  color write masks, 4× MSAA with resolve targets + sample mask +
  alpha-to-coverage, multiple color targets (up to 8),
  viewport/scissor/blend-constant, render bundles, occlusion queries,
  read-only depth/stencil attachments, debug groups/markers.
- **Shadow mapping works end-to-end**: comparison samplers
  (`sampler_comparison`), depth-sample-type bindings, and depth bias are all
  wired and verified by a depth-pass → comparison-sample test.
- **Textures**: 1D/2D/3D/array/cube dimensions, per-mip / per-layer /
  origin-targeted uploads, format-reinterpreting views (srgb), samplers with
  per-axis address modes + LOD clamps + anisotropy, storage textures, all
  four copy directions with origins/mips/layers, `clearBuffer`, 39 standard
  formats from `r8unorm` to `rgba32float` + `depth16unorm`/`stencil8`, and
  feature-gated compressed formats (BC1–7, ETC2/EAC, ASTC) with automatic
  block-size math — `writeTexture` derives the block-aligned stride from
  the format, and `GpuTextureFormatInfo` exposes the layout helpers.
- **Buffers**: zero-copy `writeBuffer`/`writeTexture` uploads, `mapRead`,
  and the mapped-write path (`mappedAtCreation` / `mapWrite` +
  `writeMapped` straight into mapped GPU memory).
- **Introspection**: native-backed getters for buffer usage, texture
  properties, and query-set type; wrapper-tracked buffer map state.
- **Timing**: GPU timestamp queries on both pass types plus encoder-level
  `writeTimestamp` (feature-gated), with `queue.timestampPeriod` for
  tick→ns conversion.
- **Presentation**: the `WebGpuView` widget composites frames into the widget
  tree via Flutter's texture registry. On Apple platforms frames pipeline 3
  deep through a render-target ring, each presented by a single GPU→GPU
  Metal blit into an IOSurface-backed pixel buffer. On Android frames render
  straight into a real `WGPUSurface` swapchain built from the
  `SurfaceProducer`'s window — zero copies, no intermediate targets. A
  portable CPU-readback presenter is the automatic fallback elsewhere.

See [PARITY.md](PARITY.md) for the audit of this surface against the full
WebGPU spec — what's covered and the probe-verified upstream gaps in
wgpu-native v29 (e.g. async pipeline creation is unimplemented upstream).

## Usage

### Adapter and device

Everything starts with an adapter (a physical GPU) and a device (your
logical connection to it):

```dart
import 'package:nitro_webgpu/nitro_webgpu.dart';

final adapter = await Gpu.requestAdapter();
print('${adapter.info.device} on ${adapter.backendType.name}');

final device = await adapter.requestDevice();
```

Features and limits are opt-in at device creation:

```dart
final device = await adapter.requestDevice(
  requireTimestampQueries: true,
  requiredFeatures: {GpuFeature.textureCompressionBc},
  requiredLimits: GpuRequiredLimits(maxColorAttachmentBytesPerSample: 40),
);
```

### Compute, end to end

A WGSL kernel that doubles 64 floats — upload, dispatch, read back:

```dart
final module = await device.createShaderModule('''
@group(0) @binding(0) var<storage, read_write> data: array<f32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  data[id.x] = data[id.x] * 2.0;
}''');

final pipeline = await device.createComputePipeline(module: module);

final values = Float32List.fromList([for (var i = 1; i <= 64; i++) i * 1.0]);
final storage = device.createBuffer(
    size: values.lengthInBytes,
    usage: GpuBufferUsage.storage | GpuBufferUsage.copySrc);
device.queue.writeBuffer(storage, values.buffer.asUint8List());

final layout = pipeline.getBindGroupLayout(0);
final bind = device.createBindGroup(layout: layout, entries: [
  GpuBufferBinding(binding: 0, buffer: storage),
]);

final staging = device.createBuffer(
    size: values.lengthInBytes,
    usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);

final encoder = device.createCommandEncoder();
encoder.beginComputePass()
  ..setPipeline(pipeline)
  ..setBindGroup(0, bind)
  ..dispatchWorkgroups(1)
  ..end();
encoder.copyBufferToBuffer(storage, staging);
device.queue.submit([encoder.finish()]);

final doubled = Float32List.view((await staging.mapRead()).buffer);
// doubled: [2.0, 4.0, 6.0, ..., 128.0]
```

### Rendering to the screen

`WebGpuView` embeds GPU-rendered content in the widget tree. Each frame,
`onFrame` receives a target sized to the widget (in physical pixels) —
record a render pass into `target.view` and submit:

```dart
WebGpuView(
  device: device,
  onFrame: (target, elapsed) {
    final encoder = device.createCommandEncoder();
    encoder.beginRenderPass(colorAttachments: [
      GpuColorAttachmentInfo(view: target.view, clearColor: GpuColor.black),
    ])
      ..setPipeline(trianglePipeline) // created once, outside onFrame
      ..draw(3)
      ..end();
    device.queue.submit([encoder.finish()]);
  },
)
```

Create pipelines against `target.targetFormat` (`bgra8Unorm` on all current
presenters). Two knobs matter under load: `renderScale` decouples render
resolution from widget size (0.5 renders a quarter of the pixels and
upscales on the GPU — the basis for dynamic resolution), and frames are
paced drop-latest, so a slow frame never queues behind a stale one.

### Texture uploads — including compressed

`writeTexture` derives the copy layout from the texture's format: stride,
mip dimensions, and data-size validation are automatic.

```dart
final tex = device.createTexture(
    width: 256,
    height: 256,
    format: GpuTextureFormat.rgba8Unorm,
    usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst);
device.queue.writeTexture(tex, pixels); // tight 256×4 stride derived

// Compressed formats need zero block math — the 4×4-block stride of BC1
// is derived the same way:
final bc1 = device.createTexture(
    width: 512,
    height: 512,
    format: GpuTextureFormat.bc1RgbaUnorm,
    usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst);
device.queue.writeTexture(bc1, bc1Blocks);
```

When you do need the numbers (asset pipelines, buffer↔texture copies),
`GpuTextureFormatInfo` exposes them for every format:
`format.blockWidth`, `format.bytesPerBlock`, `format.bytesPerRowFor(width)`,
`format.byteLengthFor(width, height)`.

### Errors you can actually read

Shader and pipeline creation are *checked*: validation failures throw a
typed exception carrying naga's full message, including source spans.

```dart
try {
  await device.createShaderModule(brokenWgsl);
} on GpuValidationException catch (e) {
  print(e.message); // e.g. "error: unknown identifier 'positon' ..."
}
```

Everything else is observable through WebGPU's standard mechanisms:
`device.pushErrorScope(...)` / `popErrorScope()` for scoped capture, and
`device.onUncapturedError` as a stream of anything that escapes.

### Resource lifetime

Every wrapper (`GpuBuffer`, `GpuTexture`, pipelines, views, …) owns its
native handle. Call `dispose()` when you're done — that's the contract. A
GC `Finalizer` will reclaim leaked handles eventually, but it's a safety
net, not a strategy.

## Platform status

| Platform | Status |
|---|---|
| macOS | ✅ Full suite green — Metal GPU-blit presenter, dynamic resolution |
| iOS | ✅ Full suite green on simulator (Metal blit active); physical device pending signing |
| Android | ✅ Full suite green on the emulator **and** a physical OnePlus CPH2447 (Adreno 740, Android 16) — zero-copy `SurfaceProducer` → `WGPUSurface` swapchain, 120 Hz with ADPF performance hints |
| Windows | ✅ CI-verified on D3D12 WARP — CPU-readback presenter via `FlutterDesktopPixelBuffer` textures; 42/42 main + 30/31 complex (one documented upstream skip: read-only depth aborts wgpu's D3D12 backend) |
| Linux | ✅ CI-verified on lavapipe Vulkan — CPU-readback presenter via `FlPixelBufferTexture`; 42/42 main + 31/31 complex. The instance defaults to Vulkan-only on desktop Linux (wgpu's GL/EGL probe races the GTK engine's EGL context) |
| Web | 📐 designed-for (`navigator.gpu` via JS interop), deferred |

Known upstream gaps (wgpu-native v29.0.1.1, all probe-verified): the
device-lost callback never fires (the `onLost` stream is plumbed and will
work once upstream delivers events); unbalanced `popErrorScope` would abort
the process, so the plugin tracks scope depth natively and throws a Dart
error instead; `wgpuBufferWriteMappedRange` and `getCompilationInfo` are
unimplemented upstream (the plugin works around the former and returns empty
diagnostics for the latter); a command buffer that failed validation at
`finish` aborts the process at submit — keep checked creates around
validation-sensitive encodes. Details in [PARITY.md](PARITY.md).

## Example app

`example/` is a gallery: multi-view rendering with per-view FPS overlays, a
live WGSL shader toy (editor, speed/param controls, inline naga errors,
hot-swap that keeps the last good pipeline), heavy-scene benchmarks with
`[gpu-perf]` console counters and real per-pass GPU milliseconds from
timestamp queries, and dynamic resolution scaling that holds the display's
max refresh rate under load.

```sh
cd example
flutter run -d macos
```

## Tests

Two integration suites under `example/integration_test/`:

- `wgpu_instance_test.dart` — 42 per-feature tests, milestone by milestone
  (link proof → adapter/device → compute → offscreen render → textures →
  3D → parity batches → presentation ring → timestamps → stress).
- `wgpu_parity_complex_test.dart` — 31 cross-feature scenarios shaped like
  real renderers: a fully GPU-driven frame (compute writes the vertex
  buffer, indirect args, and a texture; `drawIndirect` consumes all three),
  deferred-shading MRT → lighting, shadow mapping with comparison samplers,
  back-face culling, point topology, custom blend + write masks, feature
  round-trips, copy origins, mapped-write uploads, alpha-to-coverage, srgb
  reinterpretation, read-only depth, stencil masks, bundle indirect draws,
  per-mip render targets, texture arrays with per-instance layer selection,
  bundle replay across passes, compute-pass dynamic offsets,
  stencil+scissor masking, 3D-texture slices, compressed-upload helpers
  (BC1 quadrant decode with automatic stride, format block-math, tight
  non-4-byte strides), and a 6-pass ping-pong frame graph in one submit.

```sh
cd example
flutter test integration_test -d macos
# software adapter (CI): --dart-define=WGPU_FORCE_FALLBACK=true
```

## Setup (contributors)

The wgpu-native static libraries are vendored, not committed. After cloning:

```sh
scripts/fetch_wgpu_native.sh          # fetches targets for your host OS
```

This downloads the pinned wgpu-native release (see `scripts/wgpu_native.sha256`),
verifies checksums, unpacks into `src/third_party/wgpu_native/`, and on macOS
also produces the Apple `wgpu_native.xcframework` bundles.

Regenerate bindings after editing `lib/src/nitro_webgpu.native.dart`:

```sh
scripts/gen.sh    # build_runner + swift-bridge workaround + nitrogen link/doctor
```

## Milestone log

- **M0**: wgpu-native linked, instance + version query.
- **M1a–c**: adapter/device + async plumbing + error streams; buffers +
  compute; offscreen render + readback.
- **M2.0–2.2**: presentation seam + CPU-readback reference; Metal GPU blit
  fast path; iOS (simulator) verification.
- **M2.3**: Android — core module compiled for all three ABIs, zero-copy
  presentation via `SurfaceProducer` → `ANativeWindow` → `WGPUSurface`
  swapchain; both suites green on the emulator **and** a physical 120 Hz
  device (hardware-adapter selection, 120 Hz display-mode + ADPF hints,
  flicker-free first frame, rotation-safe frame-boundary surface swaps).
- **Feature batches**: textures/samplers → 3D rendering (vertex/index/depth/
  blend/explicit layouts) → timestamp queries → parity batch (copies,
  indirect, MSAA, storage textures, mips) → parity tail (bundles, occlusion,
  cube/array/3D, MRT, dynamic offsets, stencil, requiredLimits) → complex
  parity suite.
- **P0/P1/P2 parity backlog**: primitive state, shadow-mapping enablers
  (comparison samplers, depth bias), feature enumeration, custom blend +
  write masks, copy origins, full limits, mapped writes, debug markers,
  and the P2 tail — implemented and tested.
- **Compressed-upload helpers**: `GpuTextureFormatInfo` block metadata +
  layout math on every format; `writeTexture` derives strides and mip
  dimensions automatically and validates before any native call.
- **M2.4/M2.5**: Windows + Linux presenters implemented and **CI-verified**
  — desktop plugin classes (`pluginClass` registration) hand the texture
  registrar to the present module through an `NwpTextureOps` table; the
  shared readback ring renders RGBA on desktop to match Flutter's
  pixel-buffer textures. CI debugging surfaced two real platform findings:
  wgpu's GL/EGL backend probe races the GTK engine's EGL context on Linux
  (fixed — desktop Linux instances default to Vulkan-only), and wgpu's
  D3D12 backend aborts on read-only depth attachments under WARP (one
  test skipped on Windows, upstream issue).
- **CI**: all three desktop jobs green — macOS on real Metal, Windows on
  D3D12 WARP, Linux on lavapipe under Xvfb; failure-only crash diagnostics
  (core-dump backtraces, app-stderr capture, standalone adapter probe)
  stay in the workflow for future regressions.
- **Next**: iOS physical-device signing, GPU-path presenters for desktop
  (DXGI shared handle / dmabuf).
