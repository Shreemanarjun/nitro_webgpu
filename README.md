# nitro_webgpu

**WebGPU for Flutter** — modern GPU compute and rendering from Dart, on every
platform, with one API.

[![integration tests](https://github.com/Shreemanarjun/nitro_webgpu/actions/workflows/integration_test.yml/badge.svg)](https://github.com/Shreemanarjun/nitro_webgpu/actions/workflows/integration_test.yml)

Powered by [wgpu-native](https://github.com/gfx-rs/wgpu-native) and bound
through [Nitro](https://pub.dev/packages/nitro) FFI: one shared C++
implementation wraps the standard `webgpu.h` C ABI on iOS, Android, macOS,
Windows, and Linux. The Dart surface is curated and idiomatic — typed
descriptors with sensible defaults, `Future`s instead of callbacks, and
deterministic `dispose()` everywhere — not a mechanical 1:1 binding.

```dart
// Write WGSL once — it runs on Metal, Vulkan, and D3D12.
final adapter = await Gpu.requestAdapter();
final device = await adapter.requestDevice();

final module = await device.createShaderModule('''
@group(0) @binding(0) var<storage, read_write> data: array<f32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  data[id.x] = data[id.x] * 2.0;
}''');                     // invalid WGSL? throws with naga's full message
```

And putting pixels on screen is one widget:

```dart
WebGpuView(
  device: device,
  onFrame: (target, elapsed) {
    // record + submit a render pass into target.view
  },
)
```

## Highlights

- **Full WebGPU, verified.** Compute and render pipelines, every draw
  variant, complete depth/stencil/blend state, MSAA, MRT, render bundles,
  occlusion + timestamp queries, storage textures, comparison samplers —
  exercised by **134 integration tests** across four suites on macOS
  (Metal), Windows (D3D12), Linux (Vulkan), Android, and the iOS simulator.
- **Fast by default.** Zero-copy buffer and texture uploads straight from
  Dart memory. Presentation is zero-copy on Android (frames render into a
  real swapchain on the Flutter texture), a single GPU→GPU Metal blit on
  Apple platforms, and portable CPU readback on desktop Linux/Windows.
  Drop-latest frame pacing, a `renderScale` knob for dynamic resolution,
  and verified 120 Hz on a 120 Hz device.
- **Shaders in WGSL *and* GLSL.** `createShaderModuleGlsl` ingests GLSL
  through naga, and mixed pipelines pair a GLSL fragment with a WGSL vertex
  stage — Shadertoy content runs as-is.
- **No jank from compiles.** Shader modules and pipelines build on a
  background thread; hot-swapping a live shader never stalls the UI.
- **Errors you can read.** Checked creates throw typed exceptions carrying
  naga's diagnostics with source spans; error scopes and an
  uncaptured-error stream cover everything else. Known native panic paths
  are guarded in the plugin so validation mistakes stay Dart exceptions.
- **Compressed textures without the math.** BC1–7, ETC2/EAC, and ASTC
  uploads derive their block-aligned strides automatically;
  `GpuTextureFormatInfo` exposes the layout helpers when you need numbers.
- **Real GPU timing.** Timestamp queries on both pass types give exact
  per-pass milliseconds, not frame-time guesses.
- **Web-ready API shape.** No `dart:ffi` types in the public surface, so a
  future `navigator.gpu` backend can implement the same API.

## Platform support

| Platform | Presentation path | Status |
|---|---|---|
| macOS | GPU→GPU Metal blit into IOSurface | ✅ CI-verified on real Metal |
| iOS | GPU→GPU Metal blit into IOSurface | ✅ Simulator CI-verified; physical device pending signing |
| Android | Zero-copy `WGPUSurface` swapchain | ✅ CI-verified (emulator) + physical 120 Hz device |
| Windows | CPU readback (DXGI fast path planned) | ✅ CI-verified on D3D12 WARP |
| Linux | CPU readback (dmabuf fast path planned) | ✅ CI-verified on Vulkan lavapipe |
| Web | `navigator.gpu` via JS interop | 📐 designed for, not yet built |

## Usage

### Adapter and device

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

Upload, dispatch, read back:

```dart
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
// [2.0, 4.0, 6.0, ..., 128.0]
```

### Rendering to the screen

Each frame, `onFrame` receives a target sized to the widget in physical
pixels — record a render pass into `target.view` and submit:

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

Create pipelines against `target.targetFormat`. Under load, `renderScale`
decouples render resolution from widget size (0.5 renders a quarter of the
pixels and upscales on the GPU), and frames are paced drop-latest so a slow
frame never queues behind a stale one.

### GLSL shaders — run Shadertoy content

GLSL modules are single-stage (entry point `main`) and pair with a WGSL
vertex stage:

```dart
final fs = await device.createShaderModuleGlsl('''
#version 450
layout(location = 0) out vec4 fragColor;
void main() { fragColor = vec4(0.0, 1.0, 0.0, 1.0); }
''', stage: GpuShaderStage.fragment);

final pipeline = await device.createRenderPipeline(
  module: wgslVertexModule,
  fragmentModule: fs,
  fragmentEntryPoint: 'main',
  targetFormat: GpuTextureFormat.rgba8Unorm,
);
```

### Texture uploads — including compressed

`writeTexture` derives the copy layout from the texture's format: strides,
mip dimensions, and data-size validation are automatic.

```dart
device.queue.writeTexture(tex, pixels);      // tight stride derived

// Compressed formats need zero block math:
device.queue.writeTexture(bc1Texture, bc1Blocks);
// When you do need the numbers:
GpuTextureFormat.bc1RgbaUnorm.byteLengthFor(512, 512);
```

### Errors you can actually read

```dart
try {
  await device.createShaderModule(brokenWgsl);
} on GpuValidationException catch (e) {
  print(e.message); // naga's diagnostics, with source spans
}

device.onUncapturedError.listen((e) => log(e.message));
```

### Resource lifetime

Every wrapper owns its native handle — call `dispose()` when done. A GC
`Finalizer` reclaims leaked handles eventually, but it's a safety net, not
a strategy.

## Example app

`example/` is a full gallery:

- **Shader showcase** — 18 production-ready techniques across four
  categories: holographic cards, mesh gradients, shimmer skeletons, neon
  borders, ripple transitions; halftone/Kuwahara/chromatic-aberration
  filters and a multi-pass bloom pipeline; reaction-diffusion, Game of
  Life, ink flow, boids flocking, fireworks; 2D dynamic lighting, fog of
  war, a **playable Breakout whose entire game state — ball physics,
  paddle, 32 bricks — lives in GPU data texels**, and a **keyboard-driven
  endless 3D racer** (OutRun-style road, rival traffic, shader-rendered
  score HUD, game-over-on-collision with best-score tracking — all
  simulated on the GPU, steered with arrows/WASD) — every showcase
  verified by a pixel test.
- **Shadertoy player** — paste GLSL straight from shadertoy.com or WGSL
  snippets: mouse interaction, multi-pass Buffer A feedback, texture
  channels, inline compile errors.
- **GPU particles** — a live-editable compute kernel drives 100k instanced
  particles that never leave the GPU.
- **WGSL shader toy** and a **compute shader toy** (Slang-playground
  `imageMain` kernels), both with hot-swap that keeps the last good
  pipeline.
- **Benchmarks** with real per-pass GPU milliseconds from timestamp
  queries, multi-view rendering with per-view FPS overlays, and dynamic
  resolution scaling that holds the display's max refresh rate under load.

```sh
cd example
flutter run -d macos
```

## Testing

Four integration suites — 134 tests — run on every platform in CI:

- `wgpu_instance_test.dart` (57) — per-feature coverage, from link proof
  through adapter/device, compute, offscreen rendering, textures, GLSL,
  the Shadertoy engine, particles, presentation, and timestamps.
- `wgpu_parity_complex_test.dart` (31) — cross-feature scenarios shaped
  like real renderers: GPU-driven indirect frames, deferred-shading MRT,
  shadow mapping, mapped-write uploads, compressed textures, and a 6-pass
  ping-pong frame graph in one submit.
- `wgpu_robustness_test.dart` (18) — production hardening: lifecycle soak,
  error paths, boundary values, concurrency, and editor-engine stress.
- `wgpu_showcase_test.dart` (28) — every gallery showcase compiles and
  renders non-degenerate frames; interactive ones react to the pointer,
  simulations provably evolve, boids stay in bounds, Breakout's paddle
  tracks the pointer, and the racer is played end-to-end by the tests:
  steering, throttle/brake physics, the ticking score HUD, a fatal
  collision, the frozen game-over screen, the fresh-press restart latch,
  and real keyboard events wired through the viewer.

```sh
cd example
flutter test integration_test -d macos
# software adapter (CI): --dart-define=WGPU_FORCE_FALLBACK=true
```

## Known limitations

- Async pipeline creation is unimplemented in wgpu-native v29 — the plugin
  compensates by running synchronous creates on a background thread.
- The device-lost callback never fires on this wgpu-native pin; the
  `onLost` stream is plumbed and will work once upstream delivers events.
- A command buffer that failed validation at `finish` aborts the process at
  submit (upstream behavior) — keep checked creates around
  validation-sensitive encodes; the plugin's wrappers validate what they
  can before native calls.
- Desktop Linux defaults to the Vulkan backend only: wgpu's GL probe races
  the Flutter GTK engine's EGL context. Pass `GpuBackend.gl` explicitly if
  you need it.
- One complex-suite test (read-only depth) is skipped on Windows pending an
  upstream D3D12 fix.

## Contributing / building from source

The wgpu-native static libraries are vendored, not committed:

```sh
scripts/fetch_wgpu_native.sh   # pinned release, checksum-verified
```

Regenerate Nitro bindings after editing the specs:

```sh
scripts/gen.sh                 # build_runner + nitrogen link + doctor
```

## Roadmap

- iOS physical-device verification (signing)
- GPU-path desktop presenters: DXGI shared handle (Windows), dmabuf (Linux)
- Web backend over `navigator.gpu`
- First pub.dev release
