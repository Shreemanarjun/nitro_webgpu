import 'package:nitro/nitro.dart';

part 'nitro_webgpu.g.dart';

/// Backend selection bits for [GpuInstanceOptions.backends].
///
/// These are curated values mapped to `WGPUInstanceBackend` flags in C++ —
/// they are not the raw ABI values.
abstract final class GpuBackend {
  /// Let wgpu pick every backend available on the platform.
  static const int all = 0;
  static const int vulkan = 1 << 0;
  static const int metal = 1 << 1;
  static const int dx12 = 1 << 2;
  static const int gl = 1 << 3;
}

/// Options for [NitroWebgpu.initInstance].
@hybridRecord
class GpuInstanceOptions {
  /// Bitmask of [GpuBackend] values; [GpuBackend.all] (0) selects all.
  final int backends;

  const GpuInstanceOptions({this.backends = GpuBackend.all});
}

@NitroModule(
  ios: NativeImpl.cpp,
  android: NativeImpl.cpp,
  macos: NativeImpl.cpp,
  windows: NativeImpl.cpp,
  linux: NativeImpl.cpp,
)
abstract class NitroWebgpu extends HybridObject {
  static final NitroWebgpu instance = _NitroWebgpuImpl();

  /// Creates the process-wide `WGPUInstance`. Idempotent.
  void initInstance(GpuInstanceOptions options);

  /// The linked wgpu-native version, e.g. `"29.0.1.1"`.
  String wgpuVersion();
}
