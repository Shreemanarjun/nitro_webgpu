/// Public, Dart-idiomatic WebGPU API.
///
/// This layer owns all handle lifetimes: every wrapper class pairs its native
/// create with the matching explicit release. `dispose()` is the contract —
/// a GC [Finalizer] is attached only as a best-effort safety net, exactly like
/// `dart:ui`'s `Image`. Nothing in this library exposes `dart:ffi` types, so a
/// future web backend can implement the same surface over `navigator.gpu`.
library;

import 'dart:async';
import 'dart:typed_data';

import '../nitro_webgpu.native.dart';

export '../nitro_webgpu.native.dart'
    show
        GpuAdapterInfo,
        GpuLimits,
        GpuBackend,
        GpuBufferUsage,
        GpuTextureUsage,
        GpuShaderStage;

/// Texture formats supported by the curated layer (raw `WGPUTextureFormat`).
enum GpuTextureFormat {
  r8Unorm(0x01),
  rg8Unorm(0x0A),
  r32Float(0x0E),
  rgba8Unorm(0x16),
  rgba8UnormSrgb(0x17),
  bgra8Unorm(0x1B),
  bgra8UnormSrgb(0x1C),
  rgba16Float(0x28),
  rgba32Float(0x29),
  depth24Plus(0x2E),
  depth32Float(0x30);

  final int raw;
  const GpuTextureFormat(this.raw);
}

/// Vertex attribute data types (raw `WGPUVertexFormat`).
enum GpuVertexFormat {
  unorm8x4(0x09),
  float16x4(0x1B),
  float32(0x1C),
  float32x2(0x1D),
  float32x3(0x1E),
  float32x4(0x1F),
  uint32(0x20),
  sint32(0x24);

  final int raw;
  const GpuVertexFormat(this.raw);
}

/// Whether a vertex buffer advances per vertex or per instance.
enum GpuVertexStepMode {
  vertex(1),
  instance(2);

  final int raw;
  const GpuVertexStepMode(this.raw);
}

/// Index buffer element type.
enum GpuIndexFormat {
  uint16(1),
  uint32(2);

  final int raw;
  const GpuIndexFormat(this.raw);
}

/// Depth/stencil comparison. Raw value = index + 1.
enum GpuCompareFunction {
  never,
  less,
  equal,
  lessEqual,
  greater,
  notEqual,
  greaterEqual,
  always;

  int get raw => index + 1;
}

/// Color blend presets for render pipelines. Raw value = index.
enum GpuBlendMode {
  /// Opaque — no blending.
  none,

  /// Classic alpha: `src.rgb·a + dst.rgb·(1−a)`.
  alpha,

  /// Additive: `src + dst`.
  additive,

  /// Premultiplied alpha: `src + dst·(1−a)`.
  premultiplied,
}

/// One vertex attribute for [GpuVertexLayout].
class GpuVertexAttr {
  final GpuVertexFormat format;
  final int offset;
  final int shaderLocation;

  const GpuVertexAttr({
    required this.format,
    required this.offset,
    required this.shaderLocation,
  });
}

/// The layout of one vertex buffer slot.
class GpuVertexLayout {
  final int arrayStride;
  final GpuVertexStepMode stepMode;
  final List<GpuVertexAttr> attributes;

  const GpuVertexLayout({
    required this.arrayStride,
    this.stepMode = GpuVertexStepMode.vertex,
    required this.attributes,
  });
}

/// Resource types for explicit bind group layout entries.
enum GpuBindingType {
  uniformBuffer(1),
  storageBuffer(2),
  readOnlyStorageBuffer(3),
  sampler(4),
  texture(5),

  /// Write-only rgba8unorm 2D storage texture (compute image output).
  storageTexture(6);

  final int raw;
  const GpuBindingType(this.raw);
}

/// One entry for [GpuDevice.createBindGroupLayout].
class GpuLayoutEntry {
  final int binding;

  /// Bitmask of [GpuShaderStage] values.
  final int visibility;
  final GpuBindingType type;

  const GpuLayoutEntry({
    required this.binding,
    required this.visibility,
    required this.type,
  });
}

/// What happens to an attachment at the start of a render pass.
enum GpuLoadOp {
  load(1),
  clear(2);

  final int raw;
  const GpuLoadOp(this.raw);
}

/// What happens to an attachment at the end of a render pass.
enum GpuStoreOp {
  store(1),
  discard(2);

  final int raw;
  const GpuStoreOp(this.raw);
}

/// An RGBA color with double components in [0, 1].
class GpuColor {
  final double r, g, b, a;
  const GpuColor(this.r, this.g, this.b, [this.a = 1.0]);

  static const black = GpuColor(0, 0, 0);
  static const transparent = GpuColor(0, 0, 0, 0);
}

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

/// Thrown by checked creates ([GpuDevice.createShaderModule],
/// [GpuDevice.createComputePipeline]) when WebGPU validation fails.
class GpuValidationException implements Exception {
  final String operation;
  final String message;
  const GpuValidationException(this.operation, this.message);

  @override
  String toString() => 'GpuValidationException($operation): $message';
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

  /// Whether devices from this adapter can measure GPU pass times with
  /// timestamp queries.
  bool get supportsTimestampQueries {
    _checkAlive();
    return NitroWebgpu.instance.adapterHasTimestampQuery(_address);
  }

  /// Requests a logical device. The adapter stays usable afterwards and may
  /// be disposed independently of the device.
  ///
  /// Set [requireTimestampQueries] (after checking
  /// [supportsTimestampQueries]) to enable [GpuDevice.createTimestampQuerySet].
  Future<GpuDevice> requestDevice({
    String label = '',
    bool requireTimestampQueries = false,
  }) async {
    _checkAlive();
    final address = await NitroWebgpu.instance.requestDevice(
      _address,
      GpuDeviceDescriptor(
        label: label,
        requireTimestampQueries: requireTimestampQueries,
      ),
    );
    return GpuDevice._(address, hasTimestampQueries: requireTimestampQueries);
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

  /// Whether the device was created with the `timestamp-query` feature.
  final bool hasTimestampQueries;

  GpuDevice._(this._address, {this.hasTimestampQueries = false}) {
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

  // ── Resource creation ──────────────────────────────────────────────────

  GpuBuffer createBuffer({
    required int size,
    required int usage,
    bool mappedAtCreation = false,
    String label = '',
  }) {
    _checkAlive();
    final address = NitroWebgpu.instance.deviceCreateBuffer(
      _address,
      GpuBufferDescriptor(
        label: label,
        size: size,
        usage: usage,
        mappedAtCreation: mappedAtCreation,
      ),
    );
    return GpuBuffer._(address, size);
  }

  /// Checked create: compiles [wgsl] and throws [GpuValidationException] on
  /// compile errors (WebGPU surfaces them asynchronously via error scopes,
  /// hence the Future).
  Future<GpuShaderModule> createShaderModule(String wgsl,
      {String label = ''}) async {
    _checkAlive();
    pushErrorScope(GpuErrorFilter.validation);
    final address = NitroWebgpu.instance
        .deviceCreateShaderModuleWgsl(_address, label, wgsl);
    final error = await popErrorScope();
    if (error != null) {
      NitroWebgpu.instance.shaderModuleRelease(address);
      throw GpuValidationException('createShaderModule', error.message);
    }
    return GpuShaderModule._(address);
  }

  /// Checked create with auto layout. Throws [GpuValidationException] if the
  /// pipeline is invalid (bad entry point, interface mismatch, …).
  Future<GpuComputePipeline> createComputePipeline({
    required GpuShaderModule module,
    String entryPoint = 'main',
    GpuPipelineLayout? layout,
    String label = '',
  }) async {
    _checkAlive();
    pushErrorScope(GpuErrorFilter.validation);
    final address = NitroWebgpu.instance.deviceCreateComputePipeline(
      _address,
      GpuComputePipelineDescriptor(
        label: label,
        moduleAddress: module._address,
        entryPoint: entryPoint,
        layoutAddress: layout?._address ?? 0,
      ),
    );
    final error = await popErrorScope();
    if (error != null) {
      NitroWebgpu.instance.computePipelineRelease(address);
      throw GpuValidationException('createComputePipeline', error.message);
    }
    return GpuComputePipeline._(address);
  }

  GpuBindGroup createBindGroup({
    required GpuBindGroupLayout layout,
    required List<GpuBinding> entries,
    String label = '',
  }) {
    _checkAlive();
    final address = NitroWebgpu.instance.deviceCreateBindGroup(
      _address,
      GpuBindGroupDescriptor(
        label: label,
        layoutAddress: layout._address,
        entries: [for (final e in entries) e._toEntry()],
      ),
    );
    return GpuBindGroup._(address);
  }

  GpuSampler createSampler({
    GpuFilterMode magFilter = GpuFilterMode.linear,
    GpuFilterMode minFilter = GpuFilterMode.linear,
    GpuFilterMode mipmapFilter = GpuFilterMode.nearest,
    GpuAddressMode addressMode = GpuAddressMode.clampToEdge,
    String label = '',
  }) {
    _checkAlive();
    final address = NitroWebgpu.instance.deviceCreateSampler(
      _address,
      GpuSamplerDescriptor(
        label: label,
        magFilter: magFilter.raw,
        minFilter: minFilter.raw,
        mipmapFilter: mipmapFilter.raw,
        addressModeU: addressMode.raw,
        addressModeV: addressMode.raw,
        addressModeW: addressMode.raw,
      ),
    );
    return GpuSampler._(address);
  }

  GpuCommandEncoder createCommandEncoder({String label = ''}) {
    _checkAlive();
    final address =
        NitroWebgpu.instance.deviceCreateCommandEncoder(_address, label);
    return GpuCommandEncoder._(address);
  }

  /// Checked create of a timestamp query set with [count] slots. Requires the
  /// device to have been created with `requireTimestampQueries` — throws
  /// [GpuValidationException] otherwise.
  Future<GpuQuerySet> createTimestampQuerySet(int count) async {
    _checkAlive();
    pushErrorScope(GpuErrorFilter.validation);
    final address =
        NitroWebgpu.instance.deviceCreateTimestampQuerySet(_address, count);
    final error = await popErrorScope();
    if (error != null) {
      NitroWebgpu.instance.querySetRelease(address);
      throw GpuValidationException('createTimestampQuerySet', error.message);
    }
    return GpuQuerySet._(address, count);
  }

  GpuTexture createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    required int usage,
    int mipLevelCount = 1,
    int sampleCount = 1,
    String label = '',
  }) {
    _checkAlive();
    final address = NitroWebgpu.instance.deviceCreateTexture(
      _address,
      GpuTextureDescriptor(
        label: label,
        width: width,
        height: height,
        format: format.raw,
        usage: usage,
        mipLevelCount: mipLevelCount,
        sampleCount: sampleCount,
      ),
    );
    return GpuTexture._(address, width, height, format);
  }

  /// Checked create of a render pipeline: one shader [module] for both
  /// stages, one color target of [targetFormat]. Throws
  /// [GpuValidationException] on invalid pipelines.
  ///
  /// [vertexBuffers] describe the vertex fetch layout; [depthFormat] enables
  /// depth testing against a matching pass depth attachment; [blend] selects
  /// a blending preset; [layout] overrides auto bind-group layout.
  Future<GpuRenderPipeline> createRenderPipeline({
    required GpuShaderModule module,
    required GpuTextureFormat targetFormat,
    String vertexEntryPoint = 'vs_main',
    String fragmentEntryPoint = 'fs_main',
    List<GpuVertexLayout> vertexBuffers = const [],
    GpuPipelineLayout? layout,
    GpuTextureFormat? depthFormat,
    bool depthWriteEnabled = true,
    GpuCompareFunction depthCompare = GpuCompareFunction.less,
    GpuBlendMode blend = GpuBlendMode.none,
    int sampleCount = 1,
    String label = '',
  }) async {
    _checkAlive();
    pushErrorScope(GpuErrorFilter.validation);
    final address = NitroWebgpu.instance.deviceCreateRenderPipeline(
      _address,
      GpuRenderPipelineDescriptor(
        label: label,
        moduleAddress: module._address,
        vertexEntryPoint: vertexEntryPoint,
        fragmentEntryPoint: fragmentEntryPoint,
        targetFormat: targetFormat.raw,
        vertexBuffers: [
          for (final vb in vertexBuffers)
            GpuVertexBufferLayout(
              arrayStride: vb.arrayStride,
              stepMode: vb.stepMode.raw,
              attributes: [
                for (final a in vb.attributes)
                  GpuVertexAttribute(
                    format: a.format.raw,
                    offset: a.offset,
                    shaderLocation: a.shaderLocation,
                  ),
              ],
            ),
        ],
        layoutAddress: layout?._address ?? 0,
        depthFormat: depthFormat?.raw ?? 0,
        depthWriteEnabled: depthWriteEnabled,
        depthCompare: depthCompare.raw,
        blendMode: blend.index,
        sampleCount: sampleCount,
      ),
    );
    final error = await popErrorScope();
    if (error != null) {
      NitroWebgpu.instance.renderPipelineRelease(address);
      throw GpuValidationException('createRenderPipeline', error.message);
    }
    return GpuRenderPipeline._(address);
  }

  /// Explicit bind group layout (alternative to
  /// `pipeline.getBindGroupLayout` auto layouts).
  GpuBindGroupLayout createBindGroupLayout({
    required List<GpuLayoutEntry> entries,
    String label = '',
  }) {
    _checkAlive();
    final address = NitroWebgpu.instance.deviceCreateBindGroupLayout(
      _address,
      GpuBindGroupLayoutDescriptor(
        label: label,
        entries: [
          for (final e in entries)
            GpuBindGroupLayoutEntry(
              binding: e.binding,
              visibility: e.visibility,
              type: e.type.raw,
            ),
        ],
      ),
    );
    return GpuBindGroupLayout._(address);
  }

  /// Pipeline layout from up to four bind group layouts.
  GpuPipelineLayout createPipelineLayout({
    required List<GpuBindGroupLayout> layouts,
    String label = '',
  }) {
    _checkAlive();
    if (layouts.length > 4) {
      throw ArgumentError('at most 4 bind group layouts are supported');
    }
    final address = NitroWebgpu.instance.deviceCreatePipelineLayout(
      _address,
      GpuPipelineLayoutDescriptor(
        label: label,
        layout0: layouts.isNotEmpty ? layouts[0]._address : 0,
        layout1: layouts.length > 1 ? layouts[1]._address : 0,
        layout2: layouts.length > 2 ? layouts[2]._address : 0,
        layout3: layouts.length > 3 ? layouts[3]._address : 0,
      ),
    );
    return GpuPipelineLayout._(address);
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

  void _checkAlive() {
    if (_disposed) throw StateError('GpuQueue used after dispose()');
  }

  /// Copies [data] into [buffer] at [bufferOffset]. wgpu copies synchronously;
  /// [data] may be reused immediately.
  void writeBuffer(GpuBuffer buffer, Uint8List data, {int bufferOffset = 0}) {
    _checkAlive();
    NitroWebgpu.instance
        .queueWriteBuffer(_address, buffer._address, bufferOffset, data);
  }

  /// Copies [data] into mip 0 of a 2D [texture] (usage must include
  /// [GpuTextureUsage.copyDst]). [bytesPerRow] defaults to the tight stride
  /// for 4-byte formats; wgpu copies synchronously.
  /// [width]/[height] default to the texture's mip-0 size; pass explicit
  /// dimensions when writing to a higher [mipLevel].
  void writeTexture(GpuTexture texture, Uint8List data,
      {int? bytesPerRow, int mipLevel = 0, int? width, int? height}) {
    _checkAlive();
    final w = width ?? texture.width;
    final h = height ?? texture.height;
    NitroWebgpu.instance.queueWriteTexture(
      _address,
      texture._address,
      data,
      bytesPerRow ?? w * 4,
      w,
      h,
      mipLevel,
    );
  }

  /// Submits command buffers in order. They are invalid after submission and
  /// are disposed automatically.
  void submit(List<GpuCommandBuffer> commandBuffers) {
    _checkAlive();
    for (final cb in commandBuffers) {
      NitroWebgpu.instance.queueSubmitOne(_address, cb._address);
      cb._disposeAfterSubmit();
    }
  }

  /// Resolves when all submitted work on this queue has completed on the GPU.
  Future<void> onSubmittedWorkDone() {
    _checkAlive();
    return NitroWebgpu.instance.queueOnSubmittedWorkDone(_address);
  }

  /// Nanoseconds per timestamp tick (multiply resolved timestamp deltas by
  /// this to get nanoseconds).
  double get timestampPeriod {
    _checkAlive();
    return NitroWebgpu.instance.queueTimestampPeriod(_address);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.queueRelease(_address);
  }
}

/// A GPU buffer.
class GpuBuffer {
  static final Finalizer<int> _finalizer =
      Finalizer((address) => NitroWebgpu.instance.bufferRelease(address));

  final int _address;

  /// Byte size the buffer was created with.
  final int size;
  bool _disposed = false;

  GpuBuffer._(this._address, this.size) {
    _finalizer.attach(this, _address, detach: this);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('GpuBuffer used after dispose()');
  }

  /// Maps the buffer for reading (requires [GpuBufferUsage.mapRead]) and
  /// resolves with a copy of the range. The buffer is unmapped before the
  /// future resolves.
  Future<Uint8List> mapRead({int offset = 0, int? size}) async {
    _checkAlive();
    final n = size ?? (this.size - offset);
    final mapped =
        await NitroWebgpu.instance.bufferMapRead(_address, offset, n);
    return mapped.data;
  }

  /// WebGPU `buffer.destroy()` — frees the GPU memory now. The Dart object
  /// still needs [dispose].
  void destroy() {
    _checkAlive();
    NitroWebgpu.instance.bufferDestroy(_address);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.bufferRelease(_address);
  }
}

/// A compiled WGSL shader module.
class GpuShaderModule {
  static final Finalizer<int> _finalizer =
      Finalizer((address) => NitroWebgpu.instance.shaderModuleRelease(address));

  final int _address;
  bool _disposed = false;

  GpuShaderModule._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.shaderModuleRelease(_address);
  }
}

/// A compute pipeline (auto layout).
class GpuComputePipeline {
  static final Finalizer<int> _finalizer = Finalizer(
      (address) => NitroWebgpu.instance.computePipelineRelease(address));

  final int _address;
  bool _disposed = false;

  GpuComputePipeline._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('GpuComputePipeline used after dispose()');
  }

  GpuBindGroupLayout getBindGroupLayout(int groupIndex) {
    _checkAlive();
    final address = NitroWebgpu.instance
        .computePipelineGetBindGroupLayout(_address, groupIndex);
    return GpuBindGroupLayout._(address);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.computePipelineRelease(_address);
  }
}

/// A pipeline layout (see [GpuDevice.createPipelineLayout]).
class GpuPipelineLayout {
  static final Finalizer<int> _finalizer = Finalizer(
      (address) => NitroWebgpu.instance.pipelineLayoutRelease(address));

  final int _address;
  bool _disposed = false;

  GpuPipelineLayout._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.pipelineLayoutRelease(_address);
  }
}

/// A bind group layout (from [GpuComputePipeline.getBindGroupLayout],
/// [GpuRenderPipeline.getBindGroupLayout], or
/// [GpuDevice.createBindGroupLayout]).
class GpuBindGroupLayout {
  static final Finalizer<int> _finalizer = Finalizer(
      (address) => NitroWebgpu.instance.bindGroupLayoutRelease(address));

  final int _address;
  bool _disposed = false;

  GpuBindGroupLayout._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.bindGroupLayoutRelease(_address);
  }
}

/// One resource binding for [GpuDevice.createBindGroup].
sealed class GpuBinding {
  const GpuBinding(this.binding);

  final int binding;

  GpuBindGroupEntry _toEntry();
}

/// Binds a buffer (uniform or storage, per the pipeline's layout).
class GpuBufferBinding extends GpuBinding {
  final GpuBuffer buffer;
  final int offset;

  /// Byte size of the binding; `null` binds the whole buffer.
  final int? size;

  const GpuBufferBinding({
    required int binding,
    required this.buffer,
    this.offset = 0,
    this.size,
  }) : super(binding);

  @override
  GpuBindGroupEntry _toEntry() => GpuBindGroupEntry(
        binding: binding,
        bufferAddress: buffer._address,
        offset: offset,
        size: size ?? -1,
      );
}

/// Binds a sampler.
class GpuSamplerBinding extends GpuBinding {
  final GpuSampler sampler;

  const GpuSamplerBinding({required int binding, required this.sampler})
      : super(binding);

  @override
  GpuBindGroupEntry _toEntry() => GpuBindGroupEntry(
        binding: binding,
        samplerAddress: sampler._address,
      );
}

/// Binds a texture view for sampling in shaders.
class GpuTextureBinding extends GpuBinding {
  final GpuTextureView view;

  const GpuTextureBinding({required int binding, required this.view})
      : super(binding);

  @override
  GpuBindGroupEntry _toEntry() => GpuBindGroupEntry(
        binding: binding,
        textureViewAddress: view._address,
      );
}

/// Texel filtering for samplers. Raw value = index + 1.
enum GpuFilterMode {
  nearest,
  linear;

  int get raw => index + 1;
}

/// Texture coordinate wrapping. Raw values 1–3.
enum GpuAddressMode {
  clampToEdge,
  repeat,
  mirrorRepeat;

  int get raw => index + 1;
}

/// A texture sampler (see [GpuDevice.createSampler]).
class GpuSampler {
  static final Finalizer<int> _finalizer =
      Finalizer((address) => NitroWebgpu.instance.samplerRelease(address));

  final int _address;
  bool _disposed = false;

  GpuSampler._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.samplerRelease(_address);
  }
}

/// A bind group.
class GpuBindGroup {
  static final Finalizer<int> _finalizer =
      Finalizer((address) => NitroWebgpu.instance.bindGroupRelease(address));

  final int _address;
  bool _disposed = false;

  GpuBindGroup._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.bindGroupRelease(_address);
  }
}

/// Records GPU commands. Call [finish] to produce a [GpuCommandBuffer];
/// the encoder is consumed by it.
class GpuCommandEncoder {
  static final Finalizer<int> _finalizer = Finalizer(
      (address) => NitroWebgpu.instance.commandEncoderRelease(address));

  final int _address;
  bool _disposed = false;

  GpuCommandEncoder._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('GpuCommandEncoder used after finish()');
  }

  GpuComputePassEncoder beginComputePass({
    String label = '',
    GpuTimestampWrites? timestampWrites,
  }) {
    _checkAlive();
    final address = NitroWebgpu.instance.encoderBeginComputePass(
      _address,
      GpuComputePassDescriptor(
        label: label,
        timestampQuerySetAddress: timestampWrites?.querySet._address ?? 0,
        timestampBeginIndex: timestampWrites?.beginIndex ?? 0,
        timestampEndIndex: timestampWrites?.endIndex ?? 1,
      ),
    );
    return GpuComputePassEncoder._(address);
  }

  GpuRenderPassEncoder beginRenderPass({
    required List<GpuColorAttachmentInfo> colorAttachments,
    GpuDepthAttachmentInfo? depthAttachment,
    String label = '',
    GpuTimestampWrites? timestampWrites,
  }) {
    _checkAlive();
    final address = NitroWebgpu.instance.encoderBeginRenderPass(
      _address,
      GpuRenderPassDescriptor(
        label: label,
        colorAttachments: [
          for (final a in colorAttachments)
            GpuColorAttachment(
              viewAddress: a.view._address,
              loadOp: a.loadOp.raw,
              storeOp: a.storeOp.raw,
              clearR: a.clearColor.r,
              clearG: a.clearColor.g,
              clearB: a.clearColor.b,
              clearA: a.clearColor.a,
              resolveTargetAddress: a.resolveTarget?._address ?? 0,
            ),
        ],
        timestampQuerySetAddress: timestampWrites?.querySet._address ?? 0,
        timestampBeginIndex: timestampWrites?.beginIndex ?? 0,
        timestampEndIndex: timestampWrites?.endIndex ?? 1,
        depthViewAddress: depthAttachment?.view._address ?? 0,
        depthLoadOp: depthAttachment?.loadOp.raw ?? 2,
        depthStoreOp: depthAttachment?.storeOp.raw ?? 2,
        depthClearValue: depthAttachment?.clearValue ?? 1.0,
      ),
    );
    return GpuRenderPassEncoder._(address);
  }

  /// Resolves [queryCount] slots of [querySet] (raw 8-byte GPU ticks per
  /// slot) into [destination], which needs [GpuBufferUsage.queryResolve].
  void resolveQuerySet(
    GpuQuerySet querySet, {
    required GpuBuffer destination,
    int firstQuery = 0,
    int? queryCount,
    int destinationOffset = 0,
  }) {
    _checkAlive();
    NitroWebgpu.instance.encoderResolveQuerySet(
      _address,
      querySet._address,
      firstQuery,
      queryCount ?? querySet.count,
      destination._address,
      destinationOffset,
    );
  }

  /// Copies [source] buffer contents into mip [mipLevel] of [texture].
  /// [bytesPerRow] must be a multiple of 256 for buffer-to-texture copies.
  void copyBufferToTexture(GpuBuffer source, GpuTexture texture,
      {int? bytesPerRow, int mipLevel = 0, int? width, int? height}) {
    _checkAlive();
    final w = width ?? texture.width;
    final h = height ?? texture.height;
    NitroWebgpu.instance.encoderCopyBufferToTexture(
        _address, source._address, bytesPerRow ?? w * 4, texture._address,
        mipLevel, w, h);
  }

  /// Copies a region between mip 0 of two textures (defaults to the source's
  /// full size).
  void copyTextureToTexture(GpuTexture source, GpuTexture destination,
      {int? width, int? height}) {
    _checkAlive();
    NitroWebgpu.instance.encoderCopyTextureToTexture(
        _address,
        source._address,
        destination._address,
        width ?? source.width,
        height ?? source.height);
  }

  /// Copies the full contents of [texture] (mip 0) into [destination].
  /// [bytesPerRow] must be a multiple of 256; defaults to `width * 4`
  /// (valid for 4-byte formats when the row size meets the alignment).
  void copyTextureToBuffer(GpuTexture texture, GpuBuffer destination,
      {int? bytesPerRow}) {
    _checkAlive();
    NitroWebgpu.instance.encoderCopyTextureToBuffer(
      _address,
      texture._address,
      destination._address,
      bytesPerRow ?? texture.width * 4,
      texture.width,
      texture.height,
    );
  }

  void copyBufferToBuffer(GpuBuffer source, GpuBuffer destination,
      {int sourceOffset = 0, int destinationOffset = 0, int? size}) {
    _checkAlive();
    NitroWebgpu.instance.encoderCopyBufferToBuffer(
      _address,
      source._address,
      sourceOffset,
      destination._address,
      destinationOffset,
      size ?? source.size,
    );
  }

  /// Finishes recording. The encoder is consumed and must not be used again.
  GpuCommandBuffer finish({String label = ''}) {
    _checkAlive();
    final address = NitroWebgpu.instance.encoderFinish(_address, label);
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.commandEncoderRelease(_address);
    return GpuCommandBuffer._(address);
  }

  /// Abandons an unfinished encoder.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.commandEncoderRelease(_address);
  }
}

/// Records a compute pass. Call [end] before [GpuCommandEncoder.finish].
class GpuComputePassEncoder {
  static final Finalizer<int> _finalizer = Finalizer(
      (address) => NitroWebgpu.instance.computePassRelease(address));

  final int _address;
  bool _disposed = false;

  GpuComputePassEncoder._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('GpuComputePassEncoder used after end()');
  }

  void setPipeline(GpuComputePipeline pipeline) {
    _checkAlive();
    NitroWebgpu.instance.computePassSetPipeline(_address, pipeline._address);
  }

  void setBindGroup(int index, GpuBindGroup bindGroup) {
    _checkAlive();
    NitroWebgpu.instance
        .computePassSetBindGroup(_address, index, bindGroup._address);
  }

  void dispatchWorkgroups(int x, [int y = 1, int z = 1]) {
    _checkAlive();
    NitroWebgpu.instance.computePassDispatchWorkgroups(_address, x, y, z);
  }

  /// [indirectBuffer] holds `[x, y, z]` workgroup counts as u32 at [offset].
  void dispatchWorkgroupsIndirect(GpuBuffer indirectBuffer, {int offset = 0}) {
    _checkAlive();
    NitroWebgpu.instance.computePassDispatchWorkgroupsIndirect(
        _address, indirectBuffer._address, offset);
  }

  /// Ends the pass and releases it.
  void end() {
    _checkAlive();
    NitroWebgpu.instance.computePassEnd(_address);
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.computePassRelease(_address);
  }
}

/// A 2D GPU texture.
class GpuTexture {
  static final Finalizer<int> _finalizer =
      Finalizer((address) => NitroWebgpu.instance.textureRelease(address));

  final int _address;
  final int width;
  final int height;
  final GpuTextureFormat format;
  bool _disposed = false;

  GpuTexture._(this._address, this.width, this.height, this.format) {
    _finalizer.attach(this, _address, detach: this);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('GpuTexture used after dispose()');
  }

  /// Creates a view. [mipLevelCount] null = all remaining levels.
  GpuTextureView createView(
      {String label = '', int baseMipLevel = 0, int? mipLevelCount}) {
    _checkAlive();
    final address = NitroWebgpu.instance
        .textureCreateView(_address, label, baseMipLevel, mipLevelCount ?? 0);
    return GpuTextureView._(address);
  }

  /// WebGPU `texture.destroy()` — frees the GPU memory now. The Dart object
  /// still needs [dispose].
  void destroy() {
    _checkAlive();
    NitroWebgpu.instance.textureDestroy(_address);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.textureRelease(_address);
  }
}

/// A view onto a [GpuTexture].
class GpuTextureView {
  static final Finalizer<int> _finalizer =
      Finalizer((address) => NitroWebgpu.instance.textureViewRelease(address));

  final int _address;
  final bool _owned;
  bool _disposed = false;

  GpuTextureView._(this._address) : _owned = true {
    _finalizer.attach(this, _address, detach: this);
  }

  /// A borrowed view whose lifetime is owned by native code (e.g. a
  /// presenter's render target) — [dispose] is a no-op.
  GpuTextureView.borrowed(int address)
      : _address = address,
        _owned = false;

  void dispose() {
    if (_disposed || !_owned) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.textureViewRelease(_address);
  }
}

/// The render target a [WebGpuView] frame renders into: a borrowed texture
/// view plus its pixel size and format (create pipelines with
/// [targetFormat]).
class GpuRenderTarget {
  final GpuTextureView view;
  final int width;
  final int height;
  final GpuTextureFormat targetFormat;

  const GpuRenderTarget({
    required this.view,
    required this.width,
    required this.height,
    required this.targetFormat,
  });
}

/// A render pipeline (see [GpuDevice.createRenderPipeline]).
class GpuRenderPipeline {
  static final Finalizer<int> _finalizer = Finalizer(
      (address) => NitroWebgpu.instance.renderPipelineRelease(address));

  final int _address;
  bool _disposed = false;

  GpuRenderPipeline._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('GpuRenderPipeline used after dispose()');
  }

  GpuBindGroupLayout getBindGroupLayout(int groupIndex) {
    _checkAlive();
    final address = NitroWebgpu.instance
        .renderPipelineGetBindGroupLayout(_address, groupIndex);
    return GpuBindGroupLayout._(address);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.renderPipelineRelease(_address);
  }
}

/// The depth attachment for [GpuCommandEncoder.beginRenderPass]. The view
/// must be a [GpuTextureFormat.depth24Plus] / [GpuTextureFormat.depth32Float]
/// texture matching the pipeline's `depthFormat`.
class GpuDepthAttachmentInfo {
  final GpuTextureView view;
  final GpuLoadOp loadOp;
  final GpuStoreOp storeOp;
  final double clearValue;

  const GpuDepthAttachmentInfo({
    required this.view,
    this.loadOp = GpuLoadOp.clear,
    this.storeOp = GpuStoreOp.discard,
    this.clearValue = 1.0,
  });
}

/// One color attachment for [GpuCommandEncoder.beginRenderPass].
class GpuColorAttachmentInfo {
  final GpuTextureView view;
  final GpuLoadOp loadOp;
  final GpuStoreOp storeOp;
  final GpuColor clearColor;

  /// MSAA resolve destination (single-sampled) when [view] is multisampled.
  final GpuTextureView? resolveTarget;

  const GpuColorAttachmentInfo({
    required this.view,
    this.loadOp = GpuLoadOp.clear,
    this.storeOp = GpuStoreOp.store,
    this.clearColor = GpuColor.black,
    this.resolveTarget,
  });
}

/// Records a render pass. Call [end] before [GpuCommandEncoder.finish].
class GpuRenderPassEncoder {
  static final Finalizer<int> _finalizer =
      Finalizer((address) => NitroWebgpu.instance.renderPassRelease(address));

  final int _address;
  bool _disposed = false;

  GpuRenderPassEncoder._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('GpuRenderPassEncoder used after end()');
  }

  void setPipeline(GpuRenderPipeline pipeline) {
    _checkAlive();
    NitroWebgpu.instance.renderPassSetPipeline(_address, pipeline._address);
  }

  void setBindGroup(int index, GpuBindGroup bindGroup) {
    _checkAlive();
    NitroWebgpu.instance
        .renderPassSetBindGroup(_address, index, bindGroup._address);
  }

  void setVertexBuffer(int slot, GpuBuffer buffer, {int offset = 0}) {
    _checkAlive();
    NitroWebgpu.instance
        .renderPassSetVertexBuffer(_address, slot, buffer._address, offset);
  }

  void setIndexBuffer(GpuBuffer buffer, GpuIndexFormat format,
      {int offset = 0}) {
    _checkAlive();
    NitroWebgpu.instance.renderPassSetIndexBuffer(
        _address, buffer._address, format.raw, offset);
  }

  void draw(int vertexCount,
      {int instanceCount = 1, int firstVertex = 0, int firstInstance = 0}) {
    _checkAlive();
    NitroWebgpu.instance.renderPassDraw(
        _address, vertexCount, instanceCount, firstVertex, firstInstance);
  }

  void setViewport(double x, double y, double width, double height,
      {double minDepth = 0.0, double maxDepth = 1.0}) {
    _checkAlive();
    NitroWebgpu.instance
        .renderPassSetViewport(_address, x, y, width, height, minDepth, maxDepth);
  }

  void setScissorRect(int x, int y, int width, int height) {
    _checkAlive();
    NitroWebgpu.instance
        .renderPassSetScissorRect(_address, x, y, width, height);
  }

  void setBlendConstant(GpuColor color) {
    _checkAlive();
    NitroWebgpu.instance.renderPassSetBlendConstant(
        _address, color.r, color.g, color.b, color.a);
  }

  /// [indirectBuffer] holds `[vertexCount, instanceCount, firstVertex,
  /// firstInstance]` as u32 at [offset] (usage: [GpuBufferUsage.indirect]).
  void drawIndirect(GpuBuffer indirectBuffer, {int offset = 0}) {
    _checkAlive();
    NitroWebgpu.instance
        .renderPassDrawIndirect(_address, indirectBuffer._address, offset);
  }

  /// [indirectBuffer] holds `[indexCount, instanceCount, firstIndex,
  /// baseVertex, firstInstance]` at [offset].
  void drawIndexedIndirect(GpuBuffer indirectBuffer, {int offset = 0}) {
    _checkAlive();
    NitroWebgpu.instance.renderPassDrawIndexedIndirect(
        _address, indirectBuffer._address, offset);
  }

  void drawIndexed(int indexCount,
      {int instanceCount = 1,
      int firstIndex = 0,
      int baseVertex = 0,
      int firstInstance = 0}) {
    _checkAlive();
    NitroWebgpu.instance.renderPassDrawIndexed(_address, indexCount,
        instanceCount, firstIndex, baseVertex, firstInstance);
  }

  /// Ends the pass and releases it.
  void end() {
    _checkAlive();
    NitroWebgpu.instance.renderPassEnd(_address);
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.renderPassRelease(_address);
  }
}

/// A timestamp query set (see [GpuDevice.createTimestampQuerySet]).
class GpuQuerySet {
  static final Finalizer<int> _finalizer =
      Finalizer((address) => NitroWebgpu.instance.querySetRelease(address));

  final int _address;

  /// Number of timestamp slots.
  final int count;
  bool _disposed = false;

  GpuQuerySet._(this._address, this.count) {
    _finalizer.attach(this, _address, detach: this);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.querySetRelease(_address);
  }
}

/// Where a pass writes its begin/end GPU timestamps.
class GpuTimestampWrites {
  final GpuQuerySet querySet;
  final int beginIndex;
  final int endIndex;

  const GpuTimestampWrites({
    required this.querySet,
    this.beginIndex = 0,
    this.endIndex = 1,
  });
}

/// A finished, submittable list of GPU commands.
class GpuCommandBuffer {
  static final Finalizer<int> _finalizer = Finalizer(
      (address) => NitroWebgpu.instance.commandBufferRelease(address));

  final int _address;
  bool _disposed = false;

  GpuCommandBuffer._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void _disposeAfterSubmit() => dispose();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.commandBufferRelease(_address);
  }
}
