# nitro_webgpu

WebGPU for Flutter, powered by [wgpu-native](https://github.com/gfx-rs/wgpu-native)
and bound through [Nitro](https://pub.dev/packages/nitro) FFI.

One shared C++ implementation (`src/HybridNitroWebgpu.cpp`) wraps the standard
`webgpu.h` C ABI on all five native platforms (iOS, Android, macOS, Windows,
Linux). The public Dart API is a curated, Dart-idiomatic layer — not a 1:1
binding of the WebGPU C API — with deterministic `dispose()` everywhere and a
GC `Finalizer` safety net behind it.

## What works today

Verified by **50 integration tests** on macOS (Metal) and the iOS simulator:

- **Core**: adapter/device acquisition with `requiredLimits`, error scopes,
  uncaptured-error stream, checked creates that surface WGSL/naga errors as
  typed Dart exceptions.
- **Compute**: pipelines (auto or explicit layout), dispatch (direct +
  indirect), storage buffers/textures, dynamic bind-group offsets.
- **Rendering**: vertex/index buffers with attribute layouts, instancing,
  every draw variant (indexed/indirect/indexed-indirect), depth testing,
  full stencil state (`depth24plus-stencil8`, ops, references), blend
  presets, 4× MSAA with resolve targets, multiple color targets (up to 4),
  viewport/scissor/blend-constant, render bundles, occlusion queries.
- **Textures**: 1D/2D/3D/array/cube dimensions, per-mip and per-layer uploads
  and views, samplers, storage textures, all four copy directions,
  ~15 formats from `r8unorm` to `rgba32float`.
- **Timing**: GPU timestamp queries on both pass types (feature-gated), with
  `queue.timestampPeriod` for tick→ns conversion.
- **Presentation**: the `WebGpuView` widget composites frames into the widget
  tree via Flutter's texture registry, pipelined 3 frames deep with
  backpressure. On Apple platforms each frame is a single GPU→GPU Metal blit
  into an IOSurface-backed pixel buffer (no CPU readback); a portable
  CPU-readback presenter is the automatic fallback elsewhere.

See [PARITY.md](PARITY.md) for the audit of this surface against the full
WebGPU spec: what's covered, what's curated-by-design, and the ranked backlog
(cull mode/topology exposure, shadow-mapping samplers + depth bias, feature
enumeration, custom blend state, copy origins, extended formats).

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
| Android | 🔜 M2.3 — `SurfaceProducer` + real `WGPUSurface` planned |
| Windows | 🔜 M2.4 — core API compiles, presenter = CPU readback first |
| Linux | 🔜 M2.5 — core API compiles, presenter = CPU readback first |
| Web | 📐 designed-for (`navigator.gpu` via JS interop), deferred |

Known upstream gaps (wgpu-native v29.0.1.1): the device-lost callback never
fires (the `onLost` stream is plumbed and will work once upstream delivers
events); unbalanced `popErrorScope` would abort the process, so the plugin
tracks scope depth natively and throws a Dart error instead.

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
- `wgpu_parity_complex_test.dart` — 9 cross-feature scenarios shaped like
  real renderers: a fully GPU-driven frame (compute writes the vertex
  buffer, indirect args, and a texture; `drawIndirect` consumes all three),
  deferred-shading MRT → lighting, per-mip render targets, texture arrays
  with per-instance layer selection, bundle replay across passes,
  compute-pass dynamic offsets, stencil+scissor masking, 3D-texture slices,
  and a 6-pass ping-pong frame graph in one submit.

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
- **Feature batches**: textures/samplers → 3D rendering (vertex/index/depth/
  blend/explicit layouts) → timestamp queries → parity batch (copies,
  indirect, MSAA, storage textures, mips) → parity tail (bundles, occlusion,
  cube/array/3D, MRT, dynamic offsets, stencil, requiredLimits) → complex
  parity suite.
- **Next**: PARITY.md P0 items, Android M2.3, Windows/Linux M2.4/2.5,
  first CI run.
