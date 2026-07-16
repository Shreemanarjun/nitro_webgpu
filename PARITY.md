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
  entries (feature-gated; pass a block-aligned `bytesPerRow` to
  `writeTexture`). BC1 upload + sampling verified on Apple silicon.
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
  (Android M2.3 will consume them); `ExternalTexture` is web-only.
- Compressed-format upload *helpers* (block-size math is the caller's until
  a real asset pipeline lands).

## Upstream gaps in wgpu-native v29.0.1.1 (probe-verified)

- `wgpuBufferWriteMappedRange` and mutable `wgpuBufferGetMappedRange` are
  `todo!()` panics — `writeMapped` goes through
  `wgpuBufferGetConstMappedRange` instead (same host-visible mapping;
  round-trip probe-verified for both mapping paths).
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
