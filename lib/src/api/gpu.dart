/// Public, Dart-idiomatic WebGPU API.
///
/// This layer owns all handle lifetimes: every wrapper class pairs its native
/// create with the matching explicit release. `dispose()` is the contract —
/// a GC [Finalizer] is attached only as a best-effort safety net, exactly like
/// `dart:ui`'s `Image`. Nothing in this library exposes `dart:ffi` types, so a
/// future web backend can implement the same surface over `navigator.gpu`.
library;

import 'dart:async';

import '../nitro_webgpu.native.dart';

export '../nitro_webgpu.native.dart'
    show GpuAdapterInfo, GpuLimits, GpuBackend;

/// Power preference for [Gpu.requestAdapter]. Raw value = index.
enum GpuPowerPreference { undefined, lowPower, highPerformance }

/// Which native graphics API an adapter runs on. Raw value = index.
enum GpuBackendType {
  undefined,
  nullBackend,
  webgpu,
  d3d11,
  d3d12,
  metal,
  vulkan,
  openGL,
  openGLES;

  static GpuBackendType fromRaw(int raw) =>
      (raw >= 0 && raw < values.length) ? values[raw] : undefined;
}

/// Physical adapter category. Raw value = index + 1.
enum GpuAdapterType {
  discreteGpu,
  integratedGpu,
  cpu,
  unknown;

  static GpuAdapterType fromRaw(int raw) =>
      (raw >= 1 && raw <= values.length) ? values[raw - 1] : unknown;
}

/// WebGPU error categories. Raw value = index + 1.
enum GpuErrorType {
  noError,
  validation,
  outOfMemory,
  internal,
  unknown;

  static GpuErrorType fromRaw(int raw) =>
      (raw >= 1 && raw <= values.length) ? values[raw - 1] : unknown;
}

/// Error-scope filter. Raw value = index + 1.
enum GpuErrorFilter { validation, outOfMemory, internal }

/// Why a device was lost. Raw values 1–4.
enum GpuDeviceLostReason {
  unknown,
  destroyed,
  callbackCancelled,
  failedCreation;

  static GpuDeviceLostReason fromRaw(int raw) =>
      (raw >= 1 && raw <= values.length) ? values[raw - 1] : unknown;
}

/// An error captured by [GpuDevice.popErrorScope] or delivered on
/// [GpuDevice.onUncapturedError].
class GpuErrorEvent {
  final GpuErrorType type;
  final String message;
  const GpuErrorEvent({required this.type, required this.message});

  @override
  String toString() => 'GpuErrorEvent(${type.name}: $message)';
}

/// Delivered on [GpuDevice.onLost].
class GpuDeviceLostEvent {
  final GpuDeviceLostReason reason;
  final String message;
  const GpuDeviceLostEvent({required this.reason, required this.message});

  @override
  String toString() => 'GpuDeviceLostEvent(${reason.name}: $message)';
}

/// Entry point: instance management and adapter acquisition.
abstract final class Gpu {
  static bool _initialized = false;

  /// Creates the process-wide WebGPU instance. Idempotent; called implicitly
  /// by [requestAdapter]. Pass [backends] ([GpuBackend] bits) to restrict
  /// which native APIs wgpu may use.
  static void ensureInitialized({int backends = GpuBackend.all}) {
    if (_initialized) return;
    NitroWebgpu.instance.initInstance(GpuInstanceOptions(backends: backends));
    _initialized = true;
  }

  /// The linked wgpu-native version, e.g. `"29.0.1.1"`.
  static String get version => NitroWebgpu.instance.wgpuVersion();

  /// Requests a GPU adapter. Throws if no suitable adapter exists.
  ///
  /// Set [forceFallbackAdapter] for a software adapter (headless CI).
  static Future<GpuAdapter> requestAdapter({
    GpuPowerPreference powerPreference = GpuPowerPreference.undefined,
    bool forceFallbackAdapter = false,
    int backends = GpuBackend.all,
  }) async {
    ensureInitialized(backends: backends);
    final address = await NitroWebgpu.instance.requestAdapter(
      GpuRequestAdapterOptions(
        powerPreference: powerPreference.index,
        forceFallbackAdapter: forceFallbackAdapter,
      ),
    );
    return GpuAdapter._(address);
  }
}

/// A physical GPU (or software) adapter.
class GpuAdapter {
  static final Finalizer<int> _finalizer =
      Finalizer((address) => NitroWebgpu.instance.adapterRelease(address));

  final int _address;
  bool _disposed = false;

  GpuAdapter._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('GpuAdapter used after dispose()');
  }

  GpuAdapterInfo get info {
    _checkAlive();
    return NitroWebgpu.instance.adapterGetInfo(_address);
  }

  GpuBackendType get backendType => GpuBackendType.fromRaw(info.backendType);
  GpuAdapterType get adapterType => GpuAdapterType.fromRaw(info.adapterType);

  GpuLimits get limits {
    _checkAlive();
    return NitroWebgpu.instance.adapterGetLimits(_address);
  }

  /// Requests a logical device. The adapter stays usable afterwards and may
  /// be disposed independently of the device.
  Future<GpuDevice> requestDevice({String label = ''}) async {
    _checkAlive();
    final address = await NitroWebgpu.instance.requestDevice(
      _address,
      GpuDeviceDescriptor(label: label),
    );
    return GpuDevice._(address);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.adapterRelease(_address);
  }
}

/// A logical WebGPU device.
class GpuDevice {
  static final Finalizer<int> _finalizer =
      Finalizer((address) => NitroWebgpu.instance.deviceRelease(address));

  final int _address;
  GpuQueue? _queue;
  bool _disposed = false;

  GpuDevice._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  /// Internal: raw WGPUDevice address for sibling layers (presentation).
  int get debugAddress => _address;

  void _checkAlive() {
    if (_disposed) throw StateError('GpuDevice used after dispose()');
  }

  /// The device's default queue.
  GpuQueue get queue {
    _checkAlive();
    return _queue ??=
        GpuQueue._(NitroWebgpu.instance.deviceGetQueue(_address));
  }

  /// Errors that escaped every error scope on this device.
  Stream<GpuErrorEvent> get onUncapturedError => NitroWebgpu
      .instance.uncapturedErrors
      .where((e) => e.deviceAddress == _address)
      .map((e) => GpuErrorEvent(
            type: GpuErrorType.fromRaw(e.type),
            message: e.message,
          ));

  /// Device-lost notifications for this device.
  Stream<GpuDeviceLostEvent> get onLost => NitroWebgpu
      .instance.deviceLostEvents
      .where((e) => e.deviceAddress == _address)
      .map((e) => GpuDeviceLostEvent(
            reason: GpuDeviceLostReason.fromRaw(e.reason),
            message: e.message,
          ));

  void pushErrorScope(GpuErrorFilter filter) {
    _checkAlive();
    NitroWebgpu.instance.devicePushErrorScope(_address, filter.index + 1);
  }

  /// Resolves with the captured error, or `null` if the scope was clean.
  Future<GpuErrorEvent?> popErrorScope() async {
    _checkAlive();
    final raw = await NitroWebgpu.instance.devicePopErrorScope(_address);
    if (raw == null) return null;
    return GpuErrorEvent(
      type: GpuErrorType.fromRaw(raw.type),
      message: raw.message,
    );
  }

  /// WebGPU `device.destroy()`: tears down the device. All subsequent GPU
  /// work fails and [onLost] fires with [GpuDeviceLostReason.destroyed].
  /// The Dart object still needs [dispose] to release the native handle.
  void destroy() {
    _checkAlive();
    NitroWebgpu.instance.deviceDestroy(_address);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    _queue?.dispose();
    NitroWebgpu.instance.deviceRelease(_address);
  }
}

/// A device's command queue.
class GpuQueue {
  static final Finalizer<int> _finalizer =
      Finalizer((address) => NitroWebgpu.instance.queueRelease(address));

  final int _address;
  bool _disposed = false;

  GpuQueue._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.queueRelease(_address);
  }
}
