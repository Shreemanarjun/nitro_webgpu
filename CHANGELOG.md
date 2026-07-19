# Changelog

## 0.0.1

Initial release: WebGPU for Flutter over wgpu-native v29.0.1.1, with one
shared C++ core on every native platform and a curated, Dart-idiomatic API
(no `dart:ffi` in the public surface).

### Core API

* Adapter/device acquisition with the full 31-field `limits`/`requiredLimits`
  set, all 22 standard `GpuFeature`s (enumeration + `requiredFeatures`), and
  adapter introspection (vendor/device/backend/type).
* Compute: pipelines with auto or explicit layouts, direct + indirect
  dispatch, storage buffers/textures, dynamic bind-group offsets.
* Rendering: full primitive/depth/stencil/blend state (presets + arbitrary
  custom blend and color write masks), vertex/index buffers with 40 vertex
  formats, instancing, every draw variant in passes and bundles, 4× MSAA
  with resolve + sample mask + alpha-to-coverage, up to 8 color targets,
  render bundles, occlusion queries, read-only depth/stencil, comparison
  samplers for shadow mapping, viewport/scissor/blend-constant, debug
  groups/markers.
* Textures: 1D/2D/3D/array/cube, per-mip/per-layer/origin-targeted uploads,
  srgb-reinterpreting views, samplers (per-axis address modes, LOD clamps,
  anisotropy), storage textures, all four copy directions, 39 standard
  formats plus feature-gated compressed formats (BC1–7, ETC2/EAC, ASTC)
  with **automatic block-size math** — `writeTexture` derives block-aligned
  strides and mip dimensions from the format, and `GpuTextureFormatInfo`
  exposes `blockWidth`/`bytesPerBlock`/`bytesPerRowFor`/`byteLengthFor` for
  every format.
* Buffers: zero-copy `writeBuffer`/`writeTexture` uploads, `mapRead`, and
  mapped writes (`mappedAtCreation`/`mapWrite` + `writeMapped` straight into
  mapped GPU memory).
* GPU timing: timestamp queries on compute and render passes, encoder-level
  `writeTimestamp`, `queue.timestampPeriod`.

### Presentation

* `WebGpuView` widget composites frames through Flutter's texture registry:
  a single GPU→GPU Metal blit on macOS/iOS, a zero-copy
  `SurfaceProducer` → `ANativeWindow` → `WGPUSurface` swapchain on Android,
  and a portable CPU-readback fallback elsewhere.
* Drop-latest frame pacing, `renderScale` for dynamic resolution (render
  size decoupled from surface size via a GPU upscale blit), flicker-free
  first frame, rotation/resize-safe frame-boundary surface swaps, 120 Hz
  display-mode requests + ADPF performance hints on Android.

### Robustness

* Checked shader/pipeline creates throw `GpuValidationException` with the
  full naga error (source spans included); `onUncapturedError` stream;
  error scopes with native depth tracking (an unbalanced pop is a Dart
  error, not a process abort).
* Shader modules and pipelines compile on a background thread — no UI-thread
  stalls on hot-swap.
* Deterministic `dispose()` on every wrapper with a GC `Finalizer` safety
  net.

### Platforms

* Verified by 73 integration tests on macOS (Metal), the iOS simulator, the
  Android emulator, and a physical 120 Hz Android device (OnePlus CPH2447,
  Adreno 740). Windows/Linux: CPU-readback presenters implemented
  (`FlutterDesktopPixelBuffer` / `FlPixelBufferTexture` behind desktop
  plugin classes) and **CI-verified** — Windows on D3D12 WARP (42/42 main +
  30/31 complex; read-only depth skipped, upstream D3D12 abort), Linux on
  lavapipe Vulkan (42/42 + 31/31; desktop Linux instances default to
  Vulkan-only — wgpu's GL/EGL probe races the GTK engine's EGL context).
  Web: API designed for a future `navigator.gpu` backend.
