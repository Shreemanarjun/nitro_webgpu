# nitro_webgpu

WebGPU for Flutter, powered by [wgpu-native](https://github.com/gfx-rs/wgpu-native)
and bound through [Nitro](https://pub.dev/packages/nitro) FFI.

One shared C++ implementation (`src/HybridNitroWebgpu.cpp`) wraps the standard
`webgpu.h` C ABI on all five native platforms (iOS, Android, macOS, Windows,
Linux). The public Dart API is a curated, Dart-idiomatic layer — not a 1:1
binding of the WebGPU C API — with deterministic `dispose()` everywhere and a
GC `Finalizer` safety net behind it.

## What works today

Verified by **69 integration tests** on macOS (Metal), the iOS simulator,
and the Android emulator:

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

## Quick taste

```dart
final adapter = await Gpu.requestAdapter();
final device = await adapter.requestDevice();

final module = await device.createShaderModule('''
@group(0) @binding(0) var<storage, read_write> data: array<f32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  data[id.x] = data[id.x] * 2.0;
}''');                                    // throws GpuValidationException
                                          // with the naga error on bad WGSL
final pipeline = await device.createComputePipeline(module: module);
final buffer = device.createBuffer(
    size: 256, usage: GpuBufferUsage.storage | GpuBufferUsage.copySrc);
// … writeBuffer, bind, dispatch, copy to a mapRead staging buffer,
// then: final bytes = await staging.mapRead();
```

Rendering to the screen is one widget:

```dart
WebGpuView(
  device: device,
  onFrame: (target, dt) {
    // record + submit a render pass into target.view
  },
)
```

## Platform status

| Platform | Status |
|---|---|
| macOS | ✅ Full suite green, Metal blit presenter active |
| iOS | ✅ Full suite green on simulator (Metal blit active); physical device pending signing |
| Android | ✅ Full suite green on emulator — zero-copy `SurfaceProducer` → real `WGPUSurface` swapchain (M2.3); physical-device run pending |
| Windows | 🔜 M2.4 — core API compiles, presenter = CPU readback first |
| Linux | 🔜 M2.5 — core API compiles, presenter = CPU readback first |
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

- `wgpu_instance_test.dart` — 41 per-feature tests, milestone by milestone
  (link proof → adapter/device → compute → offscreen render → textures →
  3D → parity batches → presentation ring → timestamps → stress).
- `wgpu_parity_complex_test.dart` — 28 cross-feature scenarios shaped like
  real renderers: a fully GPU-driven frame (compute writes the vertex
  buffer, indirect args, and a texture; `drawIndirect` consumes all three),
  deferred-shading MRT → lighting, shadow mapping with comparison samplers,
  back-face culling, point topology, custom blend + write masks, feature
  round-trips, copy origins, mapped-write uploads, alpha-to-coverage, srgb
  reinterpretation, read-only depth, stencil masks, bundle indirect draws,
  per-mip render targets, texture arrays with per-instance layer selection,
  bundle replay across passes, compute-pass dynamic offsets,
  stencil+scissor masking, 3D-texture slices, and a 6-pass ping-pong frame
  graph in one submit.

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
  swapchain; both suites green on the emulator.
- **Feature batches**: textures/samplers → 3D rendering (vertex/index/depth/
  blend/explicit layouts) → timestamp queries → parity batch (copies,
  indirect, MSAA, storage textures, mips) → parity tail (bundles, occlusion,
  cube/array/3D, MRT, dynamic offsets, stencil, requiredLimits) → complex
  parity suite.
- **P0/P1/P2 parity backlog**: primitive state, shadow-mapping enablers
  (comparison samplers, depth bias), feature enumeration, custom blend +
  write masks, copy origins, full limits, mapped writes, debug markers,
  and the P2 tail — implemented and tested.
- **Next**: Android physical-device verification, Windows/Linux M2.4/2.5
  presenters, first CI run.
