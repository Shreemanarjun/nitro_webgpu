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

/// Options for [NitroWebgpu.requestAdapter].
@hybridRecord
class GpuRequestAdapterOptions {
  /// 0 = undefined, 1 = low power, 2 = high performance.
  final int powerPreference;

  /// Require a fallback (software) adapter — used by headless CI.
  final bool forceFallbackAdapter;

  const GpuRequestAdapterOptions({
    this.powerPreference = 0,
    this.forceFallbackAdapter = false,
  });
}

/// Adapter identity, from `wgpuAdapterGetInfo`.
@hybridRecord
class GpuAdapterInfo {
  final String vendor;
  final String architecture;
  final String device;
  final String description;

  /// Raw `WGPUBackendType` (5 = Metal, 6 = Vulkan, 4 = D3D12, …); the public
  /// wrapper maps this to a Dart enum.
  final int backendType;

  /// Raw `WGPUAdapterType` (1 = discrete, 2 = integrated, 3 = CPU, 4 = unknown).
  final int adapterType;

  const GpuAdapterInfo({
    required this.vendor,
    required this.architecture,
    required this.device,
    required this.description,
    required this.backendType,
    required this.adapterType,
  });
}

/// Curated subset of `WGPULimits`.
@hybridRecord
class GpuLimits {
  final int maxTextureDimension1D;
  final int maxTextureDimension2D;
  final int maxTextureDimension3D;
  final int maxTextureArrayLayers;
  final int maxBindGroups;
  final int maxBindingsPerBindGroup;
  final int maxUniformBufferBindingSize;
  final int maxStorageBufferBindingSize;
  final int minUniformBufferOffsetAlignment;
  final int minStorageBufferOffsetAlignment;
  final int maxBufferSize;
  final int maxComputeWorkgroupStorageSize;
  final int maxComputeInvocationsPerWorkgroup;
  final int maxComputeWorkgroupSizeX;
  final int maxComputeWorkgroupSizeY;
  final int maxComputeWorkgroupSizeZ;

  const GpuLimits({
    required this.maxTextureDimension1D,
    required this.maxTextureDimension2D,
    required this.maxTextureDimension3D,
    required this.maxTextureArrayLayers,
    required this.maxBindGroups,
    required this.maxBindingsPerBindGroup,
    required this.maxUniformBufferBindingSize,
    required this.maxStorageBufferBindingSize,
    required this.minUniformBufferOffsetAlignment,
    required this.minStorageBufferOffsetAlignment,
    required this.maxBufferSize,
    required this.maxComputeWorkgroupStorageSize,
    required this.maxComputeInvocationsPerWorkgroup,
    required this.maxComputeWorkgroupSizeX,
    required this.maxComputeWorkgroupSizeY,
    required this.maxComputeWorkgroupSizeZ,
  });
}

/// Descriptor for [NitroWebgpu.requestDevice].
@hybridRecord
class GpuDeviceDescriptor {
  final String label;

  const GpuDeviceDescriptor({this.label = ''});
}

/// A captured error popped from an error scope.
@hybridRecord
class GpuError {
  /// Raw `WGPUErrorType` (2 = validation, 3 = out-of-memory, 4 = internal).
  final int type;
  final String message;

  const GpuError({required this.type, required this.message});
}

/// An error that escaped every error scope on a device.
@hybridRecord
class GpuUncapturedError {
  /// Address of the `WGPUDevice` the error belongs to.
  final int deviceAddress;

  /// Raw `WGPUErrorType`.
  final int type;
  final String message;

  const GpuUncapturedError({
    required this.deviceAddress,
    required this.type,
    required this.message,
  });
}

/// Device-lost notification.
@hybridRecord
class GpuDeviceLost {
  /// Address of the lost `WGPUDevice`.
  final int deviceAddress;

  /// Raw `WGPUDeviceLostReason` (1 = unknown, 2 = destroyed, 4 = failed creation).
  final int reason;
  final String message;

  const GpuDeviceLost({
    required this.deviceAddress,
    required this.reason,
    required this.message,
  });
}

/// Low-level WebGPU module. Handles are raw native addresses (`int`) —
/// lifetime is managed by the public wrapper layer in `lib/src/api/`, which
/// pairs every create with the matching explicit `*Release` method.
@NitroModule(
  ios: NativeImpl.cpp,
  android: NativeImpl.cpp,
  macos: NativeImpl.cpp,
  windows: NativeImpl.cpp,
  linux: NativeImpl.cpp,
)
abstract class NitroWebgpu extends HybridObject {
  static final NitroWebgpu instance = _NitroWebgpuImpl();

  // ── Instance ───────────────────────────────────────────────────────────

  /// Creates the process-wide `WGPUInstance`. Idempotent.
  void initInstance(GpuInstanceOptions options);

  /// The linked wgpu-native version, e.g. `"29.0.1.1"`.
  String wgpuVersion();

  // ── Adapter ────────────────────────────────────────────────────────────

  /// Resolves with the raw `WGPUAdapter` address. Rejects if no suitable
  /// adapter exists (never resolves with 0).
  @nitroNativeAsync
  Future<int> requestAdapter(GpuRequestAdapterOptions options);

  GpuAdapterInfo adapterGetInfo(int adapter);
  GpuLimits adapterGetLimits(int adapter);
  void adapterRelease(int adapter);

  // ── Device / queue ─────────────────────────────────────────────────────

  /// Resolves with the raw `WGPUDevice` address. The device is registered
  /// with the native callback pump until [deviceRelease].
  @nitroNativeAsync
  Future<int> requestDevice(int adapter, GpuDeviceDescriptor descriptor);

  /// Returns the device's queue (+1 ref; pair with [queueRelease]).
  int deviceGetQueue(int device);

  /// WebGPU `device.destroy()`: tears the device down and fires the
  /// device-lost callback with reason `destroyed`. The handle itself still
  /// needs [deviceRelease] afterwards.
  void deviceDestroy(int device);

  void deviceRelease(int device);
  void queueRelease(int queue);

  // ── Error handling ─────────────────────────────────────────────────────

  /// filter: 1 = validation, 2 = out-of-memory, 3 = internal
  /// (raw `WGPUErrorFilter`).
  void devicePushErrorScope(int device, int filter);

  /// Resolves with the captured error, or `null` if the scope was clean.
  @nitroNativeAsync
  Future<GpuError?> devicePopErrorScope(int device);

  /// Errors that escaped every error scope, from any device.
  @NitroStream(backpressure: Backpressure.bufferDrop)
  Stream<GpuUncapturedError> get uncapturedErrors;

  /// Device-lost notifications, from any device.
  @NitroStream(backpressure: Backpressure.bufferDrop)
  Stream<GpuDeviceLost> get deviceLostEvents;
}
