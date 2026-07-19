# Dawn backend migration (feat/dawn-backend)

Goal: swap wgpu-native for [Dawn](https://dawn.googlesource.com/dawn) to get
`SharedTextureMemory` — zero-copy compositor interop on every platform (DXGI
shared handles, dma-buf, IOSurface, AHardwareBuffer) with
`BeginAccess`/`EndAccess` + `SharedFence` sync. This branch isolates the port;
`main` stays on wgpu-native throughout.

## Audited API skew (2026-07-18)

Everything the plugin calls is standard `webgpu.h` **except** the following
(exhaustive grep of `src/`):

| wgpu-native usage | Where | Dawn replacement |
|---|---|---|
| `wgpuInstanceProcessEvents` | pump loop | **standard** — no change |
| `wgpuInstanceEnumerateAdapters` ×2 | `pickHardwareAdapter` | no C-API equivalent — shim: on Dawn use `wgpuInstanceRequestAdapter` with explicit `WGPURequestAdapterOptions.backendType` preference loop (Vulkan/Metal/D3D12 before GL), or link `dawn::native::Instance::EnumerateAdapters` (C++ header) inside the shim |
| `wgpuDevicePoll` ×2 | pump loop | `wgpuDeviceTick` (Dawn ext) or futures `wgpuInstanceWaitAny` |
| `wgpuDeviceGetNativeMetalDevice` / `wgpuTextureGetNativeMetalTexture` | present core (Apple blit) | replaced wholesale by `SharedTextureMemory` IOSurface import — the presenter renders/copies into the imported texture instead of exporting handles |
| `WGPUShaderSourceGLSL` | `createShaderModuleGlsl` | Dawn/Tint has no GLSL front end — add glslang→SPIR-V, feed `WGPUShaderSourceSPIRV` (Dawn's spirv ingestion feature). Biggest single work item |
| `wgpuSetLogCallback` / `wgpuSetLogLevel` | instance init | per-device `WGPULoggingCallbackInfo` on the device descriptor |
| `WGPUInstanceExtras.backends` | instance init (backend mask) | no instance-level mask — express as `WGPURequestAdapterOptions.backendType` at adapter request |
| `WGPUNativeFeature_TimestampQueryInsideEncoders` | requestDevice | Dawn feature `ChromiumExperimentalTimestampQueryInsidePasses` (name check pending against dawn.json) |

Open compatibility questions to resolve with the first audit compile
(`-fsyntax-only` of `HybridNitroWebgpu.cpp` against Dawn's generated
`webgpu.h`):

- Does Dawn's generated header carry the upstream `WGPU_*_INIT` macros we use
  throughout? (webgpu-headers has them; Dawn generates from `dawn.json`.)
- Struct/callback-info revision skew (both track upstream webgpu-headers, but
  at different snapshots).
- `WGPUSurfaceSourceAndroidNativeWindow` etc. naming for the Android
  swapchain path.

## Presenter redesign on Dawn (the payoff)

One uniform flow on all five platforms:

1. Platform side allocates the compositor-shareable resource (D3D11
   `MISC_SHARED` texture / dma-buf / IOSurface / AHardwareBuffer) — exactly
   what each Flutter embedder can already composite.
2. Import it: `wgpuDeviceImportSharedTextureMemory(device, &desc)` →
   `wgpuSharedTextureMemoryCreateTexture` → a regular `WGPUTexture`.
3. Per frame: `BeginAccess` → `copyTextureToTexture(ring → imported)` (or
   render straight into it) → `EndAccess` (returns the `SharedFence` the
   compositor waits on).

Deletes: the Metal blit shim, the desktop CPU readback sinks, the Android GL
`ANativeWindow_lock` fallback (GL-compat can import AHardwareBuffer), and the
readback ring stays only as an internal render target.

## Build/vendor pipeline

- Local dev build: `~/.cache/nitro_webgpu/dawn-src`, CMake +
  `DAWN_FETCH_DEPENDENCIES=ON` + `DAWN_BUILD_MONOLITHIC_LIBRARY=SHARED` →
  single `webgpu_dawn` shared library exporting the C API.
- Vendoring: `scripts/fetch_dawn.sh` will build per target (macOS/iOS/Android
  via toolchain files; Windows/Linux in CI) and stage into
  `src/third_party/dawn/<target>/` mirroring the wgpu-native layout, selected
  by a `NITRO_WEBGPU_BACKEND=dawn` CMake/podspec switch.
- CI: a `dawn` matrix dimension building the example + running the four
  suites, alongside the existing wgpu-native jobs.

## P0 results (2026-07-18)

- Dawn monolithic Release build works on macOS out of the box:
  `~/.cache/nitro_webgpu/dawn-src/out/src/dawn/native/libwebgpu_dawn.dylib`
  (CMake + `DAWN_FETCH_DEPENDENCIES=ON` + `DAWN_BUILD_MONOLITHIC_LIBRARY=SHARED`).
- **Audit compile: the whole core TU (HybridNitroWebgpu.cpp incl.
  present_core) had only 11 errors against Dawn's generated headers**, all
  from three sites (`mapBackends`/`WGPUInstanceBackend`, `wgpuGetVersion`,
  `wgpuQueueGetTimestampPeriod`) — now shimmed. Dawn's header carries the
  same upstream `WGPU_*_INIT` macros and struct shapes; the standard-API
  surface is source-compatible.
- Core now compiles CLEAN under `-DNITRO_WEBGPU_BACKEND_DAWN` **and**
  unchanged under wgpu-native (macOS objc++ + Android NDK syntax clean;
  all four macOS suites green after the shim refactor: 57/31/18/28).
- Runtime smoke against libwebgpu_dawn: instance → Metal adapter
  ("Apple M1 Pro") → device via the standard callback flow, and
  `wgpuAdapterHasFeature(SharedTextureMemoryIOSurface) == true` — the
  zero-copy interop feature is present and requestable.

## Physical-device verification (2026-07-19, OnePlus CPH2447 / Adreno 740)

- wgpu sanity: main 56+1 — all recent main-line work green on real hardware.
- **Dawn on real Vulkan: robustness 18/18 (GLSL green with the staged NDK
  glslang!), showcase 28/28**, main/complex green except one quirk:
- **Dawn/Adreno quirk (upstream-investigation item)**: CPU-written
  (`writeBuffer`) indirect args silently draw nothing — Dawn's
  indirect-validation compute prepass misreads them. GPU-authored args work
  (the GPU-driven-frame test passes), and SwiftShader is fine on both.
  The two affected tests skip via `skipDawnHardwareCpuIndirect`.
- Android ABI coverage: Dawn built + staged (stripped, 12–18 MB) for
  arm64-v8a, armeabi-v7a, and x86_64; the gradle ABI gate now includes any
  staged ABI. glslang staged for arm64 (NDK static build,
  `NITRO_WEBGPU_HAS_GLSLANG` wired in src/CMakeLists.txt).

## Distribution decision (2026-07-19)

**wgpu-native stays the default shipped backend**; Dawn is an opt-in
dual-backend option selected by the platform markers
(`scripts/set_backend_macos.sh` / `scripts/set_backend_android.sh` /
`src/third_party/BACKEND`). Two ways to obtain Dawn:

1. **Prebuilts** — push a `dawn-v*` tag: `.github/workflows/dawn_prebuilt.yml`
   builds macOS/Windows/Linux/Android artifacts and attaches them to a
   GitHub release; `scripts/fetch_dawn.sh` vendors them (mirrors the
   wgpu-native fetch flow).
2. **From source** — the `stage_dawn_*.sh` scripts against a local Dawn
   checkout (what CI's dawn lanes do, cached).

Revisit making Dawn the default once the dawn CI lanes run required (not
continue-on-error) for a few weeks and the AHardwareBuffer GL-compat lane
exists — until then wgpu-native's GL fallback covers GLES-only Android
devices, which Dawn would leave without an adapter.

## Runtime bring-up findings (2026-07-19) — read before touching Dawn code

Every one of these was diagnosed with a native probe or crash report:

1. **Thread safety is a FEATURE, not a toggle.** Dawn devices are
   single-threaded unless `WGPUFeatureName_ImplicitDeviceSynchronization`
   is in the device's requiredFeatures. A toggle string of that name is
   silently ignored. Without it: Metal `encodeSignalEvent` asserts (abort)
   when the pump's Tick races Dart-thread submits.
2. **Error scopes are PER-THREAD** (Chromium model) — a scope pushed on the
   Dart thread can never capture errors from worker-thread creates, even
   with implicit sync. The plugin emulates wgpu-native's device-wide scopes
   (gDawnScopes in HybridNitroWebgpu.cpp): push/pop never reach Dawn; the
   uncaptured-error callback routes errors into the innermost matching
   scope.
3. **SPIR-V ingestion needs three unlocks**: `-DTINT_BUILD_SPV_READER=ON`
   at Dawn build time (defaults OFF on macOS — it follows
   DAWN_ENABLE_VULKAN), the `ShaderSourceSPIRV` INSTANCE feature, and the
   `allow_unsafe_apis` toggle.
4. **Adapters are consumed** after one requestDevice unless the
   `MultipleDevicesPerAdapter` instance feature is requested.
5. **Never Tick a destroyed device** — Dawn's Metal TickImpl submits the
   pending signal event and trips a Metal assert. The pump skips devices
   marked destroyed (WgpuContext::markDestroyed).
6. **Lowered limits are not reified** — requesting a limit below the
   default grants the default (wgpu-native reifies the lower value).
   Tests gate on `isDawnBackend`.
7. **Pass-boundary timestamps can read equal** on a trivial pass (sampled
   counters on Metal); wgpu's always advance.
8. GLSL: glslang(Vulkan dialect, entry `main`)→SPIR-V→`WGPUShaderSourceSPIRV`
   works end-to-end; compile errors route through the emulated scope so
   Dart still throws `GpuValidationException` with full diagnostics.

## Dawn suite matrix on macOS (2026-07-19)

robustness 18/18 · showcase 28/28 · complex 30+1skip · main green with
documented gates (version string, limits reification, timestamp equality,
presenter uses readback until P2-v2). Presentation works via the Apple
shim's CPU-readback fallback — SharedTextureMemory IOSurface import
(P2-v2) is the remaining zero-copy upgrade.

## Phases

- [x] P0.1 branch (`feat/dawn-backend`), skew audit, this plan
- [x] P0.2 Dawn macOS build (monolithic Release, libwebgpu_dawn.dylib)
- [x] P0.3 audit compile → 11 errors → 3 shims → clean both backends
- [x] P1 backend shim (`src/nw_backend.h`): core compiles under
      `NITRO_WEBGPU_BACKEND_DAWN` on macOS, GLSL feature stubbed with a
      typed error
- [x] P2 macOS presenter on SharedTextureMemory (IOSurface import): the
      core imports the shim's pooled IOSurfaces
      (`wgpuDeviceImportSharedTextureMemory` → `CreateTexture(null)` →
      BeginAccess → GPU `copyTextureToTexture` → EndAccess → workdone →
      publish), cached per surface with pointer-reuse protection via
      geometry checks. Features `SharedTextureMemoryIOSurface` +
      `SharedFenceMTLSharedEvent` are requested when the adapter has them;
      the Swift shim's path priority is Metal-export blit (wgpu) →
      texture import (Dawn) → CPU readback. GOTCHA: SwiftPM compiles
      `macos/nitro_webgpu/Sources/NitroWebgpu/*.swift`, NOT
      `macos/Classes/` (podspec-era copies — keep all four copies in
      sync). Dawn matrix with the import presenter live: main 57/57
      (asserts the GPU path), complex 30+1, robustness 18/18,
      showcase 28/28.
- [x] P3 glslang→SPIR-V GLSL path (landed with P1/P2; gated on
      NITRO_WEBGPU_HAS_GLSLANG so platforms without a staged glslang build
      degrade to a typed error instead of failing the build)
- [x] P4 Windows: generic import ops (`nwp_presenter_set_import_ops`, the
      IOSurface path generalized) + DXGI shared-handle import branch in the
      core + `NwpTextureOps.acquire_shared_handle`/`frame_presented` +
      `WinDxgiTexture` zero-copy hookup + `presenterUsesGpuPath` honesty —
      MinGW-verified against real embedder + Dawn headers; on-platform
      proof rides the CI `dawn-*` lanes. Linux: dma-buf import is pointless
      until the Flutter GTK embedder can consume one (FlPixelBufferTexture
      only) — stays readback, documented.
- [x] P4 CI: `dawn-macos` lane (cached source build, glslang via brew,
      four suites; continue-on-error while the migration bakes).
- [x] P5 Android: Dawn cross-compiled with the NDK (host protoc needed —
      `brew install protobuf` + `-DPROTOC_EXECUTABLE`), staged via
      `scripts/stage_dawn_android.sh` (CMake lib + gradle jniLibs), backend
      switched by the `src/third_party/BACKEND` marker
      (`scripts/set_backend_android.sh`, content change = deterministic
      CMake reconfigure; plugin gradle restricts ABIs to the staged arm64
      under dawn). **Full suite matrix green on the emulator (SwiftShader
      Vulkan): main 53+4 skips (3 GLSL-pending-glslang + ring), complex
      30+1, robustness 17+1, showcase 28/28** — the standard WGPUSurface
      swapchain presenter works under Dawn unchanged. Remaining tail:
      glslang staged for Android (GLSL skips → green), armv7/x86_64 Dawn
      builds, AHardwareBuffer import for the GL-compat lane.
