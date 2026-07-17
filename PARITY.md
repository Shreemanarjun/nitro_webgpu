# WebGPU parity audit

Audited against the vendored wgpu-native **v29.0.1.1** `webgpu.h` (2026-07-16),
then the P0/P1/P2 backlog was implemented the same day. Method: diffed all 202
exported header functions against the ones the plugin calls, then
field-by-field on every descriptor struct, then enum coverage. Verified
behavior: 69 green integration tests (`example/integration_test/`).

## Covered (tested)

- **Core**: adapter/device (+ error scopes, uncaptured-error stream), full
  31-field `requiredLimits`/`limits`, **feature enumeration** —
  `adapter.features` / `device.features` / `requestDevice(requiredFeatures:)`
  over all 22 standard features.
- **Compute**: pipelines (auto/explicit layout), direct + indirect dispatch,
  storage buffers/textures, dynamic offsets, debug groups/markers.
- **Render pipelines**: full primitive state (**topology, cullMode,
  frontFace, stripIndexFormat**), vertex fetch (40 of 41 vertex formats),
  depth state incl. **depth bias/slope/clamp**, full stencil (independent
  front/back faces, read/write masks), blend presets **plus arbitrary
  `GpuBlendState`** (any op/factor pair) and per-pipeline `colorWriteMask`,
  MSAA count/**mask/alphaToCoverage**, MRT ×8.
- **Render passes**: all draw variants (indexed/indirect/indexed-indirect),
  viewport/scissor/blend-constant, occlusion queries, stencil references,
  dynamic offsets, **read-only depth/stencil attachments**, debug
  groups/markers, bundles (full state + **indirect draws**, read-only
  depth/stencil flags).
- **Samplers**: filters, per-axis address modes, **comparison samplers**
  (`sampler_comparison` — shadow mapping verified end-to-end), **LOD
  clamps, anisotropy**.
- **Bind group layouts**: buffer/sampler/texture/storage-texture types,
  dynamic offsets, view dimensions, **texture `sampleType`
  (float/unfilterable/depth/sint/uint), `multisampled`, sampler
  filtering/non-filtering/comparison**.
- **Textures**: 1D/2D/3D/array/cube, per-mip/per-layer/**origin-targeted**
  uploads, **format-reinterpreting views (`viewFormats`, e.g. srgb)**,
  39 standard formats (norm/int/float families, `rgb10a2`, `rg11b10`,
  `depth16unorm`, `stencil8`, …).
- **Copies**: all four directions with **origins, mip levels, array
  layers/3D slices, buffer offsets, and multi-slice extents**;
  `clearBuffer`.
- **Buffers**: `queue.writeBuffer` (zero-copy in), `mapRead`,
  **`mappedAtCreation` + `mapWrite` + `writeMapped` (zero-copy upload
  straight into mapped GPU memory) + `unmap`**.
- **Timing**: timestamp queries on both pass types **and encoder-level
  `writeTimestamp`** (auto-enables the wgpu-native
  `TimestampQueryInsideEncoders` extra when available).
- **Diagnostics**: `getCompilationInfo` API (see upstream note),
  debug groups/markers on encoders and both pass types.
- **Presentation**: `WebGpuView` (Metal blit presenter, DRS).

## Also covered (the former "remaining" tail)

- **Compressed texture formats**: BC1–BC7, ETC2/EAC, ASTC 4×4/8×8 enum
  entries (feature-gated). BC1 upload + sampling verified on Apple silicon.
- **Compressed-format upload helpers**: `GpuTextureFormatInfo` exposes
  `blockWidth`/`blockHeight`/`bytesPerBlock` + `bytesPerRowFor`/
  `rowsForHeight`/`byteLengthFor` for every format, and `writeTexture`
  now derives its default `bytesPerRow` from the format (tight
  block-aligned stride — fixes the old rgba-assuming `width × 4`),
  defaults `width`/`height` to the target mip's size, and validates data
  length + block-aligned origins with crisp `ArgumentError`s before any
  native call. Compressed uploads need zero hand-rolled math.
- **Introspection getters**: `buffer.usage`, all texture properties
  (`mipLevelCount`/`sampleCount`/`depthOrArrayLayers`/`dimension`/`usage`),
  `querySet.type` — native-backed; `buffer.mapState` is wrapper-tracked
  (see upstream note below).
- **8-slot caps**: color targets, bundle formats, bind group layouts, and
  dynamic offsets all take up to **8** now (5-target MRT, 5-offset
  setBindGroup, and 5-bind-group pipelines are tested — the 5×rgba8 MRT
  needs `requiredLimits(maxColorAttachmentBytesPerSample: 40)` since
  rgba8unorm costs 8 bytes/sample as a render target).

## Remaining

- `Surface*` functions — deliberately replaced by the presenter seam
  (Android M2.3 consumes them for the zero-copy swapchain; desktop
  Windows/Linux present through the CPU-readback ring instead);
  `ExternalTexture` is web-only.

## Platform gotchas (CI-verified)

- **Linux (GTK)**: wgpu's GL backend probes EGL during
  `wgpuInstanceRequestAdapter` and races the Flutter engine's EGL context —
  `egl.rs` unwraps `Err(BadAccess)` and aborts the process across the C
  ABI. Desktop Linux instances therefore default to Vulkan-only
  (`mapBackends`); pass `GpuBackend.gl` explicitly to opt back in.
- **Windows (D3D12)**: a read-only depth attachment aborts wgpu's D3D12
  backend under WARP (crashes in isolation; passes on Metal and
  Vulkan/lavapipe). The complex-suite test is skipped on Windows pending
  an upstream fix.

## Upstream gaps in wgpu-native v29.0.1.1 (probe-verified)

- `wgpuBufferWriteMappedRange` / `wgpuBufferReadMappedRange` are
  `unimplemented!()` panics (`lib.rs:707/717`) — `writeMapped` writes
  through `wgpuBufferGetMappedRange` (which IS implemented; round-trip
  probe-verified for both mapping paths).
- Complete stub inventory for v29.0.1.1 (source-audited): 35 functions in
  `unimplemented.rs` (20 `SetLabel` variants, `BufferGetMapState`,
  `Create{Compute,Render}PipelineAsync`, `DeviceGetAdapterInfo`,
  `DeviceGetLostFuture`, `ExternalTexture*`, `GetProcAddress`, WGSL
  language-feature queries, `InstanceWaitAny`,
  `ShaderModuleGetCompilationInfo`, `TextureGetTextureBindingViewDimension`)
  plus 5 inline in `lib.rs` (`GetInstanceFeatures`, `HasInstanceFeature`,
  `SupportedInstanceFeaturesFreeMembers`, `Buffer{Read,Write}MappedRange`).
  The plugin calls **none of them** (verified: stub list ∩ called-function
  list = ∅), and v29.0.1.1 is the newest upstream release.
- `wgpuDeviceCreateComputePipelineAsync` / `CreateRenderPipelineAsync` are
  unimplemented (`unimplemented.rs` panic) — async pipeline creation cannot
  ship on this pin; checked creates stay synchronous + error-scoped.
- `wgpuBufferGetMapState` is unimplemented — `buffer.mapState` is tracked in
  the Dart wrapper instead.
- `wgpuShaderModuleGetCompilationInfo` is a `todo!()` panic —
  `getCompilationInfo` resolves empty without calling it; compile errors
  still carry naga's full text via checked `createShaderModule`.
- A command buffer that failed validation at `finish` **panics the process
  at `wgpuQueueSubmit`** (not catchable, even with the uncaptured-error
  handler installed). Validate-sensitive encodes should be developed with
  error scopes around creates; this sharp edge is upstream.
- The device-lost callback never fires (`onLost` is plumbed, waiting).
- `SetImmediates` (push constants) and pipeline-statistics queries are
  nonstandard wgpu extras; not exposed.

All of the above re-tests automatically on a version bump: the probes live in
the session scratchpad pattern (`mapwrite_probe2.cpp`, `misc_probe.cpp`,
`tail_probe.cpp`) and the 69-test suite exercises every wrapped path.
