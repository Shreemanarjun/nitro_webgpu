# nitro_webgpu

WebGPU for Flutter, powered by [wgpu-native](https://github.com/gfx-rs/wgpu-native)
and bound through [Nitro](https://pub.dev/packages/nitro) FFI.

One shared C++ implementation (`src/HybridNitroWebgpu.cpp`) wraps the standard
`webgpu.h` C ABI on all five native platforms (iOS, Android, macOS, Windows,
Linux). The public Dart API is a curated, Dart-idiomatic layer — not a 1:1
binding of the ~400-function WebGPU C API.

## Status

Early development.

- **M0 (done)**: wgpu-native linked — instance creation + version query.
- **M1 (done on macOS)**: adapter/device acquisition, error scopes +
  uncaptured-error/device-lost streams, buffers (write/mapRead), WGSL shader
  modules with checked creates, compute pipelines + dispatch, offscreen
  render passes + texture readback. 14 integration tests green; Linux/Windows
  CI jobs authored, pending first run.
- **M2.0 (done on macOS)**: presentation — the `WebGpuView` widget composites
  WebGPU-rendered frames into the widget tree via Flutter's texture registry
  (portable CPU-readback presenter). Next: the zero-copy Metal blit path
  (M2.1), iOS (M2.2), Android SurfaceProducer (M2.3), Windows/Linux
  (M2.4/M2.5).
- Flutter Web (`navigator.gpu` via JS interop) is designed-for but deferred.

Known upstream gaps (wgpu-native v29.0.1.1): the device-lost callback never
fires (the `onLost` stream is plumbed and will work once upstream delivers
events); unbalanced `popErrorScope` would abort the process, so the plugin
tracks scope depth natively and throws a Dart error instead.

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

## Example

```sh
cd example
flutter test integration_test -d macos
flutter run -d macos
```
