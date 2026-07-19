# Changelog

## 0.0.1

Initial release.

- WebGPU compute and rendering for Flutter over wgpu-native v29.0.1.1,
  with an opt-in Dawn backend.
- Full WebGPU API: adapters and devices with limits/features, buffers,
  textures (incl. compressed formats), samplers, bind groups, compute and
  render pipelines, render bundles, occlusion/timestamp queries.
- WGSL and GLSL shaders compiled at runtime, off the UI thread, with
  typed validation errors.
- Widgets: `WebGpuShaderView` (fragment-only, Shadertoy-style uniforms),
  `WebGpuView` (custom render passes), `WebGpuBuilder` + `WebGpu.device()`
  (shared device), `WebGpuInputArea` + `GpuInputs` (keyboard/mouse input
  with custom key maps) — plus controllers for pause/resume, single-frame
  rendering, stats, and loading/error builders.
- Presentation per platform: Metal blit on macOS/iOS, Vulkan swapchain on
  Android (CPU fallback for GL-only devices), DXGI shared texture on
  Windows, pixel buffer on Linux.
- Setup: Android/Windows/Linux vendor the native binaries automatically at
  build time; macOS/iOS run `dart run nitro_webgpu:setup` once.
