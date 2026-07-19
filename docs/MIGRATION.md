# Migration guide

How to move to nitro_webgpu from the other ways of reaching the GPU in
Flutter — and how to move between its own backends.

## From `FragmentProgram` (built-in fragment shaders)

`FragmentProgram` gives you one fragment shader, compiled at build time,
painted by the engine. The equivalent here is `WebGpuShaderView` — with
runtime compilation, hot swap, and uniforms handled for you:

```dart
// Before: shaders/wave.frag + pubspec asset + FragmentProgram.fromAsset +
// a CustomPainter that wires uniforms by index every frame.

// After — the shader is just a string, uniforms are named, and it animates:
WebGpuShaderView(fragment: '''
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let uv = pos.xy / nw.resolution;
  return vec4f(uv, 0.5 + 0.5 * sin(nw.time), 1.0);
}
''')
```

Concept map:

| FragmentProgram | nitro_webgpu |
|---|---|
| `.frag` asset, offline compile | inline WGSL/GLSL string, runtime compile with full diagnostics |
| `setFloat(index, …)` uniforms | named `nw.time` / `nw.resolution` / `nw.mouse` built-ins (or your own uniform buffers at the raw layer) |
| `CustomPainter` + `shader` paint | `WebGpuShaderView` widget |
| Fragment stage only | full WebGPU underneath when you outgrow it |

Keep using `FragmentProgram` when: the effect ships as part of ordinary
widget painting (e.g. a shader-masked button). It's built in and needs no
native binaries.

## From `flutter_gpu` (official, experimental)

`flutter_gpu` is a custom low-level API over Impeller. Mapping:

| flutter_gpu | nitro_webgpu |
|---|---|
| `gpu.gpuContext` | `Gpu.requestAdapter()` → `adapter.requestDevice()` (or `WebGpu.device()`) |
| Shader bundles (`.shaderbundle`, offline GLSL) | `createShaderModule` (WGSL) / `createShaderModuleGlsl` at runtime |
| `RenderPass` + `commandBuffer.submit()` | `createCommandEncoder()` → `beginRenderPass` → `queue.submit` |
| `createDeviceBuffer` + `BufferView` | `createBuffer` + typed bindings (`GpuBufferBinding`) |
| Render to `gpu.RenderTarget` texture → blit into a `ui.Image` | `WebGpuView` presents directly (zero-copy/GPU-blit paths per platform) |
| Requires Impeller, master channel recommended | stable channel, any renderer |
| Compute: limited/experimental | full compute (storage textures, indirect dispatch, timestamps) |

The programming model is close (both are explicit-pass GPU APIs); the main
migration work is shaders — GLSL sources usually port to WGSL mechanically,
or run as-is through `createShaderModuleGlsl`.

## From `gpux` / `minigpu` / other WebGPU wrappers

The API shape is already WebGPU, so migration is mostly mechanical
renames — with these differences to lean on:

- **Presentation**: `WebGpuView` is a real swapchain/GPU-blit path into the
  Flutter compositor, not a readback into an image.
- **Both engines**: the same code runs on wgpu-native *and* Dawn (see
  below) — useful if you're matching browser behavior.
- **Downlevel hardware**: GLES-only Android devices still work (GL
  fallback + `supportsCompute()`/`supportsVertexStorage()` probes).
- **Errors**: checked creates throw typed exceptions carrying the full
  compiler message; error scopes and uncaptured-error streams match the
  WebGPU spec.

For compute-only code (minigpu-style): `createComputePipeline` +
`beginComputePass` + `mapRead` is the whole loop — see the README's
"Compute, end to end" example.

## Between backends: wgpu-native ⇄ Dawn

No code changes — the backend is a build-time switch:

```bash
# to Dawn (fetch prebuilts once, or stage a local build):
./scripts/fetch_dawn.sh --version dawn-v1 --targets macos-aarch64
./scripts/set_backend_macos.sh dawn      # ios / android variants exist

# back to wgpu-native (the default):
./scripts/set_backend_macos.sh wgpu
```

Behavioral differences to be aware of when switching (all covered by the
test suites): Dawn grants defaults for limits requested *below* the
default, its pass-boundary timestamps can read equal on trivial passes,
`Gpu.version` reports `0.0.0.0`, and GLSL on non-macOS platforms needs a
staged glslang. Everything else is identical — the full integration
matrix passes on both. The engineering notes behind the Dawn port live in
[DAWN_MIGRATION.md](DAWN_MIGRATION.md).

## Widget tiers — pick your level

| Tier | Widget | You write | It handles |
|---|---|---|---|
| Effects | `WebGpuShaderView` | a fragment shader string | device, uniforms, pipeline, presentation, errors, hot swap |
| Foundation | `WebGpuBuilder` + `WebGpuView` | a frame callback recording passes | device boot, loading/error states, pacing, presentation |
| Raw | the full API | everything | nothing — full control (multiple devices, compute chains, custom features/limits) |

Start at the top; drop a tier when you need more control. They compose —
a `WebGpuBuilder` device works with raw API calls too.
