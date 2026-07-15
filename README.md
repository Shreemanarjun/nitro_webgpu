# nitro_webgpu

WebGPU for Flutter, powered by [wgpu-native](https://github.com/gfx-rs/wgpu-native)
and bound through [Nitro](https://pub.dev/packages/nitro) FFI.

One shared C++ implementation (`src/HybridNitroWebgpu.cpp`) wraps the standard
`webgpu.h` C ABI on all five native platforms (iOS, Android, macOS, Windows,
Linux). The public Dart API is a curated, Dart-idiomatic layer — not a 1:1
binding of the ~400-function WebGPU C API.

## Status

Early development.

- **M0 (done)**: wgpu-native linked on macOS — instance creation + version query.
- **M1 (in progress)**: adapter/device, buffers, compute pipelines, offscreen
  render + readback, verified headless in CI on all platforms.
- **M2 (planned)**: presentation — rendering into Flutter via external
  textures (`WebGpuView` widget), Metal first.
- Flutter Web (`navigator.gpu` via JS interop) is designed-for but deferred.

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
dart run build_runner build
nitrogen link
nitrogen doctor
```

## Example

```sh
cd example
flutter test integration_test -d macos
flutter run -d macos
```
