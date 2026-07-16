# WebGPU parity audit

Audited against the vendored wgpu-native **v29.0.1.1** `webgpu.h` (2026-07-16).
Method: diffed all 202 exported header functions against the 102 the plugin
calls, then field-by-field on every descriptor struct, then enum coverage.
Verified behavior: 50 green integration tests (`example/integration_test/`).

## Covered (tested)

Instance/adapter/device (+ error scopes, uncaptured-error stream,
requiredLimits, deviceGetLimits), buffers (write/mapRead/copy), WGSL modules
(checked creates), compute (pipelines, dispatch, indirect, dynamic offsets),
render (vertex/index buffers, instancing, all draw variants incl. indirect,
viewport/scissor/blendConstant, occlusion queries, stencil ops + reference,
depth testing, blend presets, MSAA + resolve, MRT ×4, render bundles),
textures (1D/2D/3D/array/cube dims, per-mip/per-layer uploads and views,
storage textures, samplers, all copy directions), timestamp queries,
presentation (Metal blit presenter + DRS).

Of the 100 unwrapped header functions, ~70 are non-gaps: `AddRef`/`SetLabel`
bookkeeping (~44), `Surface*` (replaced by the presenter seam; Android M2.3
will use them), `ExternalTexture*` (web-only), `FreeMembers`/proc-address
plumbing. The rest are the real tail, below.

## Gaps that block common rendering techniques (P0)

| Gap | Where | Impact |
|---|---|---|
| `cullMode` / `frontFace` not plumbed | `WGPUPrimitiveState` (INIT: cull none, CCW) | No back-face culling — every closed mesh pays ~2× fragment cost |
| `topology` in spec + C++ but **not surfaced in the Dart wrapper** | `createRenderPipeline` | No line/point/strip rendering (also needs `stripIndexFormat`) |
| Depth bias (`depthBias`/`SlopeScale`/`Clamp`) not plumbed | `WGPUDepthStencilState` | Shadow mapping produces acne; decals z-fight |
| Comparison samplers (`compare`), LOD clamps, `maxAnisotropy` | `WGPUSamplerDescriptor` | `sampler_comparison`/PCF shadows impossible; no aniso filtering |
| BGL texture `sampleType` hardcoded `Float`, no `multisampled` flag, no depth sample type | explicit `GpuLayoutEntry` | Explicit layouts can't bind depth textures, sint/uint textures, or `texture_multisampled_2d` (auto-layout works — explicit is the gap) |

## Feature-surface gaps (P1)

- **Features**: header exposes 22 (`Float32Filterable`, `DepthClipControl`,
  `ShaderF16`, `Subgroups`, BC/ETC2/ASTC compression, …); only
  `TimestampQuery` is surfaced. Need `adapter.features`,
  `requestDevice(requiredFeatures:)`, `device.features`
  (`wgpuAdapterGetFeatures`/`wgpuDeviceGetFeatures`/`HasFeature` unwrapped).
- **Texture formats**: enum covers 15 of 103 (missing `depth16unorm`,
  `stencil8`, `rgb10a2unorm`, `rg11b10ufloat`, r16/rg16 families, all
  sint/uint color formats, compressed families).
- **Vertex formats**: 8 of 41 (missing 8/16-bit norm/int pairs,
  `unorm10-10-10-2`, …).
- **Custom blend state**: 3 presets only — no arbitrary factor/op pairs, no
  `min`/`max` ops, no per-target blend, no `colorWriteMask`
  (`setBlendConstant` is exposed but inert: no preset uses the
  constant-factor blend it feeds).
- **Copy origins**: all copies are origin-(0,0,0); `copyTextureToTexture` is
  mip-0-only, single-layer, depth-1; `writeTexture` lacks x/y origin. Cube
  face→face copies and atlas-region blits impossible.
- **Limits**: `GpuRequiredLimits` exposes 7 of 32 header fields; `GpuLimits`
  getter 16 of 32 (missing `maxColorAttachments`, `maxVertexAttributes`,
  per-stage counts, workgroups-per-dimension, …).

## Polish tail (P2)

- `mapWrite`/`mappedAtCreation` write path (`wgpuBufferWriteMappedRange`) —
  uploads currently always go through `queue.writeBuffer`'s extra copy.
- `wgpuDeviceCreate{Render,Compute}PipelineAsync` — checked creates are
  synchronous on the Dart thread; big PSOs could stutter a running frame.
- `wgpuShaderModuleGetCompilationInfo` — structured line/col diagnostics
  (currently: raw error-scope message string).
- `wgpuCommandEncoderClearBuffer`, encoder-level `WriteTimestamp`.
- Debug markers/groups (encoder + passes) — labels in Xcode GPU captures.
- Render bundles: `drawIndirect`/`drawIndexedIndirect` inside bundles;
  `depthReadOnly`/`stencilReadOnly` flags.
- Stencil: independent front/back face states; `stencilReadMask`/`WriteMask`
  (INIT `0xFFFFFFFF`); read-only depth/stencil pass attachments.
- Multisample `mask` / `alphaToCoverageEnabled` (INIT defaults today).
- Texture `viewFormats` (e.g. srgb reinterpret views).
- Introspection getters (`bufferGetMapState`, texture property getters,
  `querySetGetCount`) — Dart already tracks these; native would be canonical.

## Curated bounds (documented, deliberate)

- Flattened records cap: **4** color targets (WebGPU default limit is 8),
  **4** dynamic offsets, **4** bind group layouts (= spec default
  `maxBindGroups`). Raising any of these is mechanical (add fields).
- Presentation via the plugin's presenter, not `WGPUSurface` (until M2.3).
- No 1:1 `webgpu.h` exposure — `WGPUChainedStruct` never crosses the FFI.

## Upstream / out of scope

- Device-lost callback never fires in wgpu-native v29 (plumbed, waiting).
- `SetImmediates` (push constants), pipeline statistics: wgpu-native
  extensions, not standard WebGPU.
- `ExternalTexture`, canvas context: web-only; deferred with the web backend.

## Suggested order of attack

1. `createRenderPipeline(topology:, cullMode:, frontFace:)` — topology is
   already in the spec record; cull/frontFace are two record fields + two
   C++ lines each. Biggest win per line of code.
2. Sampler `compare`/LOD/anisotropy + depth-bias fields → unlocks shadow
   mapping end-to-end (add a shadow-map complex test).
3. Feature enumeration + `requiredFeatures` (records already have the
   pattern from requiredLimits).
4. Format + vertex-format enum extension (pure Dart, values pass through).
5. Custom blend + `colorWriteMask` (replace presets with an optional
   `GpuBlendState` record; keep presets as constructors).
6. Copy origins/mips/layers (extend existing copy records).
7. Explicit-BGL `sampleType`/`multisampled`; then the P2 tail.
