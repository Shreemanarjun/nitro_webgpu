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
        GpuShaderStage,
        GpuRequiredLimits,
        GpuCompilationMessage;

/// Texture formats supported by the curated layer (raw `WGPUTextureFormat`).
enum GpuTextureFormat {
  r8Unorm(0x01),
  r8Snorm(0x02),
  r8Uint(0x03),
  r8Sint(0x04),
  r16Uint(0x07),
  r16Sint(0x08),
  r16Float(0x09),
  rg8Unorm(0x0A),
  rg8Snorm(0x0B),
  rg8Uint(0x0C),
  rg8Sint(0x0D),
  r32Float(0x0E),
  r32Uint(0x0F),
  r32Sint(0x10),
  rg16Uint(0x13),
  rg16Sint(0x14),
  rg16Float(0x15),
  rgba8Unorm(0x16),
  rgba8UnormSrgb(0x17),
  rgba8Snorm(0x18),
  rgba8Uint(0x19),
  rgba8Sint(0x1A),
  bgra8Unorm(0x1B),
  bgra8UnormSrgb(0x1C),
  rgb10a2Unorm(0x1E),
  rg11b10Ufloat(0x1F),
  rg32Float(0x21),
  rg32Uint(0x22),
  rg32Sint(0x23),
  rgba16Uint(0x26),
  rgba16Sint(0x27),
  rgba16Float(0x28),
  rgba32Float(0x29),
  rgba32Uint(0x2A),
  rgba32Sint(0x2B),
  stencil8(0x2C),
  depth16Unorm(0x2D),
  depth24Plus(0x2E),
  depth24PlusStencil8(0x2F),
  depth32Float(0x30),

  // Block-compressed formats. Gated on the matching GpuFeature
  // (textureCompressionBc / Etc2 / Astc); pass an explicit block-aligned
  // `bytesPerRow` to `writeTexture` (e.g. BC1 = 8 bytes per 4×4 block row).
  bc1RgbaUnorm(0x32),
  bc1RgbaUnormSrgb(0x33),
  bc2RgbaUnorm(0x34),
  bc2RgbaUnormSrgb(0x35),
  bc3RgbaUnorm(0x36),
  bc3RgbaUnormSrgb(0x37),
  bc4RUnorm(0x38),
  bc4RSnorm(0x39),
  bc5RgUnorm(0x3A),
  bc5RgSnorm(0x3B),
  bc6hRgbUfloat(0x3C),
  bc6hRgbFloat(0x3D),
  bc7RgbaUnorm(0x3E),
  bc7RgbaUnormSrgb(0x3F),
  etc2Rgb8Unorm(0x40),
  etc2Rgb8UnormSrgb(0x41),
  etc2Rgb8A1Unorm(0x42),
  etc2Rgb8A1UnormSrgb(0x43),
  etc2Rgba8Unorm(0x44),
  etc2Rgba8UnormSrgb(0x45),
  eacR11Unorm(0x46),
  eacR11Snorm(0x47),
  eacRg11Unorm(0x48),
  eacRg11Snorm(0x49),
  astc4x4Unorm(0x4A),
  astc4x4UnormSrgb(0x4B),
  astc8x8Unorm(0x58),
  astc8x8UnormSrgb(0x59);

  final int raw;
  const GpuTextureFormat(this.raw);
}

/// Texture dimensionality (raw `WGPUTextureDimension`).
enum GpuTextureDimension {
  d1(1),
  d2(2),
  d3(3);

  final int raw;
  const GpuTextureDimension(this.raw);
}

/// Texture view dimensionality (raw `WGPUTextureViewDimension`).
enum GpuTextureViewDimension {
  d1(1),
  d2(2),
  d2Array(3),
  cube(4),
  cubeArray(5),
  d3(6);

  final int raw;
  const GpuTextureViewDimension(this.raw);
}

/// Stencil operations (raw `WGPUStencilOperation`).
enum GpuStencilOperation {
  keep(1),
  zero(2),
  replace(3),
  invert(4),
  incrementClamp(5),
  decrementClamp(6),
  incrementWrap(7),
  decrementWrap(8);

  final int raw;
  const GpuStencilOperation(this.raw);
}

/// A buffer's mapping state. Tracked by the wrapper (the native
/// `wgpuBufferGetMapState` is an unimplemented stub in wgpu-native v29).
enum GpuBufferMapState { unmapped, mapped }

/// A query set's kind (raw `WGPUQueryType`).
enum GpuQueryType {
  occlusion(1),
  timestamp(2);

  final int raw;
  const GpuQueryType(this.raw);
}

/// Primitive assembly (raw `WGPUPrimitiveTopology`).
enum GpuPrimitiveTopology {
  pointList(1),
  lineList(2),
  lineStrip(3),
  triangleList(4),
  triangleStrip(5);

  final int raw;
  const GpuPrimitiveTopology(this.raw);
}

/// Face culling (raw `WGPUCullMode`).
enum GpuCullMode {
  none(1),
  front(2),
  back(3);

  final int raw;
  const GpuCullMode(this.raw);
}

/// Which winding is front-facing (raw `WGPUFrontFace`).
enum GpuFrontFace {
  ccw(1),
  cw(2);

  final int raw;
  const GpuFrontFace(this.raw);
}

/// Blend equation operator (raw `WGPUBlendOperation`).
enum GpuBlendOperation {
  add(1),
  subtract(2),
  reverseSubtract(3),
  min(4),
  max(5);

  final int raw;
  const GpuBlendOperation(this.raw);
}

/// Blend factor (raw `WGPUBlendFactor`).
enum GpuBlendFactor {
  zero(1),
  one(2),
  src(3),
  oneMinusSrc(4),
  srcAlpha(5),
  oneMinusSrcAlpha(6),
  dst(7),
  oneMinusDst(8),
  dstAlpha(9),
  oneMinusDstAlpha(10),
  srcAlphaSaturated(11),
  constant(12),
  oneMinusConstant(13);

  final int raw;
  const GpuBlendFactor(this.raw);
}

/// A custom blend state — one equation per color/alpha component pair.
/// Feeds `pass.setBlendConstant` via the `constant` factors.
class GpuBlendState {
  final GpuBlendOperation colorOp;
  final GpuBlendFactor colorSrc;
  final GpuBlendFactor colorDst;
  final GpuBlendOperation alphaOp;
  final GpuBlendFactor alphaSrc;
  final GpuBlendFactor alphaDst;

  const GpuBlendState({
    this.colorOp = GpuBlendOperation.add,
    required this.colorSrc,
    required this.colorDst,
    this.alphaOp = GpuBlendOperation.add,
    GpuBlendFactor? alphaSrc,
    GpuBlendFactor? alphaDst,
  })  : alphaSrc = alphaSrc ?? colorSrc,
        alphaDst = alphaDst ?? colorDst;
}

/// Channel mask bits for a pipeline's `colorWriteMask`.
abstract final class GpuColorWriteMask {
  static const int red = 1;
  static const int green = 2;
  static const int blue = 4;
  static const int alpha = 8;
  static const int all = 15;
}

/// A stencil face state (used for the back-face override).
class GpuStencilFace {
  final GpuCompareFunction compare;
  final GpuStencilOperation failOp;
  final GpuStencilOperation depthFailOp;
  final GpuStencilOperation passOp;

  const GpuStencilFace({
    this.compare = GpuCompareFunction.always,
    this.failOp = GpuStencilOperation.keep,
    this.depthFailOp = GpuStencilOperation.keep,
    this.passOp = GpuStencilOperation.keep,
  });
}

/// How a texture binding is sampled in shaders
/// (raw `WGPUTextureSampleType`).
enum GpuTextureSampleType {
  float(2),
  unfilterableFloat(3),
  depth(4),
  sint(5),
  uint(6);

  final int raw;
  const GpuTextureSampleType(this.raw);
}

/// Sampler binding flavor (raw `WGPUSamplerBindingType`).
enum GpuSamplerBindingType {
  filtering(2),
  nonFiltering(3),
  comparison(4);

  final int raw;
  const GpuSamplerBindingType(this.raw);
}

/// Optional device features (raw `WGPUFeatureName`). Query support with
/// [GpuAdapter.features]; request via `requestDevice(requiredFeatures:)`.
enum GpuFeature {
  coreFeaturesAndLimits(0x01),
  depthClipControl(0x02),
  depth32FloatStencil8(0x03),
  textureCompressionBc(0x04),
  textureCompressionBcSliced3d(0x05),
  textureCompressionEtc2(0x06),
  textureCompressionAstc(0x07),
  textureCompressionAstcSliced3d(0x08),
  timestampQuery(0x09),
  indirectFirstInstance(0x0A),
  shaderF16(0x0B),
  rg11b10UfloatRenderable(0x0C),
  bgra8UnormStorage(0x0D),
  float32Filterable(0x0E),
  float32Blendable(0x0F),
  clipDistances(0x10),
  dualSourceBlending(0x11),
  subgroups(0x12),
  textureFormatsTier1(0x13),
  textureFormatsTier2(0x14),
  primitiveIndex(0x15),
  textureComponentSwizzle(0x16);

  final int raw;
  const GpuFeature(this.raw);

  static Set<GpuFeature> fromBits(int bits) => {
        for (final f in GpuFeature.values)
          if ((bits >> f.raw) & 1 == 1) f,
      };

  static int toBits(Set<GpuFeature> features) {
    var bits = 0;
    for (final f in features) {
      bits |= 1 << f.raw;
    }
    return bits;
  }
}

/// Vertex attribute data types (raw `WGPUVertexFormat`).
enum GpuVertexFormat {
  uint8(0x01),
  uint8x2(0x02),
  uint8x4(0x03),
  sint8(0x04),
  sint8x2(0x05),
  sint8x4(0x06),
  unorm8(0x07),
  unorm8x2(0x08),
  unorm8x4(0x09),
  snorm8(0x0A),
  snorm8x2(0x0B),
  snorm8x4(0x0C),
  uint16(0x0D),
  uint16x2(0x0E),
  uint16x4(0x0F),
  sint16(0x10),
  sint16x2(0x11),
  sint16x4(0x12),
  unorm16(0x13),
  unorm16x2(0x14),
  unorm16x4(0x15),
  snorm16(0x16),
  snorm16x2(0x17),
  snorm16x4(0x18),
  float16(0x19),
  float16x2(0x1A),
  float16x4(0x1B),
  float32(0x1C),
  float32x2(0x1D),
  float32x3(0x1E),
  float32x4(0x1F),
  uint32(0x20),
  uint32x2(0x21),
  uint32x3(0x22),
  uint32x4(0x23),
  sint32(0x24),
  sint32x2(0x25),
  sint32x3(0x26),
  sint32x4(0x27),
  unorm8x4Bgra(0x29);

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

  /// For [GpuBindingType.texture]: the view dimensionality shaders expect.
  final GpuTextureViewDimension viewDimension;

  /// For buffer types: bind with dynamic offsets via `setBindGroup`.
  final bool hasDynamicOffset;

  /// For [GpuBindingType.texture]: how shaders sample it (use
  /// [GpuTextureSampleType.depth] for `texture_depth_2d`).
  final GpuTextureSampleType sampleType;

  /// For [GpuBindingType.texture]: bind `texture_multisampled_2d`.
  final bool multisampled;

  /// For [GpuBindingType.sampler]: use [GpuSamplerBindingType.comparison]
  /// for `sampler_comparison` (shadow mapping).
  final GpuSamplerBindingType samplerType;

  const GpuLayoutEntry({
    required this.binding,
    required this.visibility,
    required this.type,
    this.viewDimension = GpuTextureViewDimension.d2,
    this.hasDynamicOffset = false,
    this.sampleType = GpuTextureSampleType.float,
    this.multisampled = false,
    this.samplerType = GpuSamplerBindingType.filtering,
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

  /// The optional features this adapter can enable.
  Set<GpuFeature> get features {
    _checkAlive();
    return GpuFeature.fromBits(
        NitroWebgpu.instance.adapterGetFeatures(_address));
  }

  /// Requests a logical device. The adapter stays usable afterwards and may
  /// be disposed independently of the device.
  ///
  /// Set [requireTimestampQueries] (after checking
  /// [supportsTimestampQueries]) to enable [GpuDevice.createTimestampQuerySet].
  Future<GpuDevice> requestDevice({
    String label = '',
    bool requireTimestampQueries = false,
    GpuRequiredLimits? requiredLimits,
    Set<GpuFeature> requiredFeatures = const {},
  }) async {
    _checkAlive();
    final address = await NitroWebgpu.instance.requestDevice(
      _address,
      GpuDeviceDescriptor(
        label: label,
        requireTimestampQueries: requireTimestampQueries,
        requiredLimits: requiredLimits,
        requiredFeatures: GpuFeature.toBits(requiredFeatures),
      ),
    );
    return GpuDevice._(address,
        hasTimestampQueries: requireTimestampQueries ||
            requiredFeatures.contains(GpuFeature.timestampQuery));
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
    return GpuBuffer._(address, size, mapped: mappedAtCreation);
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

  /// [compare] makes this a comparison sampler (WGSL `sampler_comparison`
  /// — bind with [GpuSamplerBindingType.comparison]). [maxAnisotropy] > 1
  /// needs all filters linear.
  GpuSampler createSampler({
    GpuFilterMode magFilter = GpuFilterMode.linear,
    GpuFilterMode minFilter = GpuFilterMode.linear,
    GpuFilterMode mipmapFilter = GpuFilterMode.nearest,
    GpuAddressMode addressMode = GpuAddressMode.clampToEdge,
    GpuAddressMode? addressModeU,
    GpuAddressMode? addressModeV,
    GpuAddressMode? addressModeW,
    GpuCompareFunction? compare,
    double lodMinClamp = 0.0,
    double lodMaxClamp = 32.0,
    int maxAnisotropy = 1,
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
        addressModeU: (addressModeU ?? addressMode).raw,
        addressModeV: (addressModeV ?? addressMode).raw,
        addressModeW: (addressModeW ?? addressMode).raw,
        compare: compare?.raw ?? 0,
        lodMinClamp: lodMinClamp,
        lodMaxClamp: lodMaxClamp,
        maxAnisotropy: maxAnisotropy,
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

  /// The device's actual limits (after `requiredLimits` were applied).
  GpuLimits get limits {
    _checkAlive();
    return NitroWebgpu.instance.deviceGetLimits(_address);
  }

  /// The features this device was created with.
  Set<GpuFeature> get features {
    _checkAlive();
    return GpuFeature.fromBits(
        NitroWebgpu.instance.deviceGetFeatures(_address));
  }

  /// Checked create of an occlusion query set with [count] slots.
  Future<GpuQuerySet> createOcclusionQuerySet(int count) async {
    _checkAlive();
    pushErrorScope(GpuErrorFilter.validation);
    final address =
        NitroWebgpu.instance.deviceCreateOcclusionQuerySet(_address, count);
    final error = await popErrorScope();
    if (error != null) {
      NitroWebgpu.instance.querySetRelease(address);
      throw GpuValidationException('createOcclusionQuerySet', error.message);
    }
    return GpuQuerySet._(address, count);
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
    GpuTextureDimension dimension = GpuTextureDimension.d2,
    int depthOrArrayLayers = 1,
    GpuTextureFormat? viewFormat,
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
        dimension: dimension.raw,
        depthOrArrayLayers: depthOrArrayLayers,
        viewFormat: viewFormat?.raw ?? 0,
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
    GpuBlendState? blendState,
    int colorWriteMask = GpuColorWriteMask.all,
    int sampleCount = 1,
    List<GpuTextureFormat> extraTargetFormats = const [],
    GpuCompareFunction stencilCompare = GpuCompareFunction.always,
    GpuStencilOperation stencilFailOp = GpuStencilOperation.keep,
    GpuStencilOperation stencilDepthFailOp = GpuStencilOperation.keep,
    GpuStencilOperation stencilPassOp = GpuStencilOperation.keep,
    GpuStencilFace? stencilBack,
    int stencilReadMask = 0xFFFFFFFF,
    int stencilWriteMask = 0xFFFFFFFF,
    GpuPrimitiveTopology topology = GpuPrimitiveTopology.triangleList,
    GpuCullMode cullMode = GpuCullMode.none,
    GpuFrontFace frontFace = GpuFrontFace.ccw,
    GpuIndexFormat? stripIndexFormat,
    int depthBias = 0,
    double depthBiasSlopeScale = 0.0,
    double depthBiasClamp = 0.0,
    int? multisampleMask,
    bool alphaToCoverage = false,
    String label = '',
  }) async {
    if (extraTargetFormats.length > 7) {
      throw ArgumentError('at most 8 color targets are supported');
    }
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
        targetFormat1: extraTargetFormats.isNotEmpty
            ? extraTargetFormats[0].raw
            : 0,
        targetFormat2:
            extraTargetFormats.length > 1 ? extraTargetFormats[1].raw : 0,
        targetFormat3:
            extraTargetFormats.length > 2 ? extraTargetFormats[2].raw : 0,
        targetFormat4:
            extraTargetFormats.length > 3 ? extraTargetFormats[3].raw : 0,
        targetFormat5:
            extraTargetFormats.length > 4 ? extraTargetFormats[4].raw : 0,
        targetFormat6:
            extraTargetFormats.length > 5 ? extraTargetFormats[5].raw : 0,
        targetFormat7:
            extraTargetFormats.length > 6 ? extraTargetFormats[6].raw : 0,
        stencilCompare: stencilCompare.raw,
        stencilFailOp: stencilFailOp.raw,
        stencilDepthFailOp: stencilDepthFailOp.raw,
        stencilPassOp: stencilPassOp.raw,
        cullMode: cullMode.raw,
        frontFace: frontFace.raw,
        stripIndexFormat: stripIndexFormat?.raw ?? 0,
        topology: topology.raw,
        depthBias: depthBias,
        depthBiasSlopeScale: depthBiasSlopeScale,
        depthBiasClamp: depthBiasClamp,
        stencilReadMask: stencilReadMask,
        stencilWriteMask: stencilWriteMask,
        stencilBackCompare: stencilBack?.compare.raw ?? 0,
        stencilBackFailOp: stencilBack?.failOp.raw ?? 0,
        stencilBackDepthFailOp: stencilBack?.depthFailOp.raw ?? 0,
        stencilBackPassOp: stencilBack?.passOp.raw ?? 0,
        colorBlendOp: blendState?.colorOp.raw ?? 0,
        colorBlendSrc: blendState?.colorSrc.raw ?? 0,
        colorBlendDst: blendState?.colorDst.raw ?? 0,
        alphaBlendOp: blendState?.alphaOp.raw ?? 0,
        alphaBlendSrc: blendState?.alphaSrc.raw ?? 0,
        alphaBlendDst: blendState?.alphaDst.raw ?? 0,
        writeMask: colorWriteMask,
        multisampleMask: multisampleMask ?? -1,
        alphaToCoverageEnabled: alphaToCoverage,
      ),
    );
    final error = await popErrorScope();
    if (error != null) {
      NitroWebgpu.instance.renderPipelineRelease(address);
      throw GpuValidationException('createRenderPipeline', error.message);
    }
    return GpuRenderPipeline._(address);
  }

  /// Records commands once for replay across passes with matching
  /// attachment formats.
  GpuRenderBundleEncoder createRenderBundleEncoder({
    required List<GpuTextureFormat> colorFormats,
    GpuTextureFormat? depthFormat,
    int sampleCount = 1,
    bool depthReadOnly = false,
    bool stencilReadOnly = false,
    String label = '',
  }) {
    _checkAlive();
    if (colorFormats.isEmpty || colorFormats.length > 8) {
      throw ArgumentError('1 to 8 color formats are supported');
    }
    final address = NitroWebgpu.instance.deviceCreateRenderBundleEncoder(
      _address,
      GpuRenderBundleEncoderDescriptor(
        label: label,
        format0: colorFormats[0].raw,
        format1: colorFormats.length > 1 ? colorFormats[1].raw : 0,
        format2: colorFormats.length > 2 ? colorFormats[2].raw : 0,
        format3: colorFormats.length > 3 ? colorFormats[3].raw : 0,
        format4: colorFormats.length > 4 ? colorFormats[4].raw : 0,
        format5: colorFormats.length > 5 ? colorFormats[5].raw : 0,
        format6: colorFormats.length > 6 ? colorFormats[6].raw : 0,
        format7: colorFormats.length > 7 ? colorFormats[7].raw : 0,
        depthFormat: depthFormat?.raw ?? 0,
        sampleCount: sampleCount,
        depthReadOnly: depthReadOnly,
        stencilReadOnly: stencilReadOnly,
      ),
    );
    return GpuRenderBundleEncoder._(address);
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
              viewDimension: e.viewDimension.raw,
              hasDynamicOffset: e.hasDynamicOffset,
              sampleType: e.sampleType.raw,
              multisampled: e.multisampled,
              samplerType: e.samplerType.raw,
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
    if (layouts.isEmpty || layouts.length > 8) {
      throw ArgumentError('1 to 8 bind group layouts are supported');
    }
    final address = NitroWebgpu.instance.deviceCreatePipelineLayout(
      _address,
      GpuPipelineLayoutDescriptor(
        label: label,
        layout0: layouts[0]._address,
        layout1: layouts.length > 1 ? layouts[1]._address : 0,
        layout2: layouts.length > 2 ? layouts[2]._address : 0,
        layout3: layouts.length > 3 ? layouts[3]._address : 0,
        layout4: layouts.length > 4 ? layouts[4]._address : 0,
        layout5: layouts.length > 5 ? layouts[5]._address : 0,
        layout6: layouts.length > 6 ? layouts[6]._address : 0,
        layout7: layouts.length > 7 ? layouts[7]._address : 0,
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
      {int? bytesPerRow,
      int mipLevel = 0,
      int arrayLayer = 0,
      int originX = 0,
      int originY = 0,
      int? width,
      int? height}) {
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
      arrayLayer,
      originX,
      originY,
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
  GpuBufferMapState _mapState;

  GpuBuffer._(this._address, this.size, {bool mapped = false})
      : _mapState = mapped ? GpuBufferMapState.mapped : GpuBufferMapState.unmapped {
    _finalizer.attach(this, _address, detach: this);
  }

  /// The buffer's current mapping state (wrapper-tracked).
  GpuBufferMapState get mapState => _mapState;

  /// The usage bitmask the buffer was created with (see [GpuBufferUsage]).
  int get usage {
    _checkAlive();
    return NitroWebgpu.instance.bufferGetUsage(_address);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('GpuBuffer used after dispose()');
  }

  /// Maps the buffer for writing (requires [GpuBufferUsage.mapWrite]).
  /// Write with [writeMapped], then call [unmap] before GPU use.
  Future<void> mapWrite({int offset = 0, int? size}) async {
    _checkAlive();
    await NitroWebgpu.instance
        .bufferMapWrite(_address, offset, size ?? this.size);
    _mapState = GpuBufferMapState.mapped;
  }

  /// Writes [data] directly into the mapped range (zero-copy: straight from
  /// the Dart buffer into mapped GPU memory). The buffer must be mapped —
  /// created with `mappedAtCreation: true` or via [mapWrite].
  void writeMapped(Uint8List data, {int offset = 0}) {
    _checkAlive();
    NitroWebgpu.instance.bufferWriteMapped(_address, offset, data);
  }

  /// Unmaps a mapped buffer so the GPU can use it.
  void unmap() {
    _checkAlive();
    NitroWebgpu.instance.bufferUnmap(_address);
    _mapState = GpuBufferMapState.unmapped;
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

  /// Structured compile diagnostics (naga messages with line/column).
  /// Valid modules usually return an empty list. Note: wgpu-native
  /// v29.0.1.1 does not implement the underlying query yet, so this
  /// currently always resolves empty — compile errors surface through the
  /// checked `createShaderModule` instead.
  Future<List<GpuCompilationMessage>> getCompilationInfo() async {
    final info =
        await NitroWebgpu.instance.shaderModuleGetCompilationInfo(_address);
    return info.messages;
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
    GpuQuerySet? occlusionQuerySet,
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
        stencilLoadOp: depthAttachment?.stencilLoadOp?.raw ?? 0,
        stencilStoreOp: depthAttachment?.stencilStoreOp?.raw ?? 0,
        stencilClearValue: depthAttachment?.stencilClearValue ?? 0,
        occlusionQuerySetAddress: occlusionQuerySet?._address ?? 0,
        depthReadOnly: depthAttachment?.depthReadOnly ?? false,
        stencilReadOnly: depthAttachment?.stencilReadOnly ?? false,
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

  /// Copies [source] buffer contents at [bufferOffset] into mip [mipLevel]
  /// of [texture] at ([originX], [originY], [originZ]). [bytesPerRow] must
  /// be a multiple of 256 for buffer-to-texture copies.
  void copyBufferToTexture(GpuBuffer source, GpuTexture texture,
      {int? bytesPerRow,
      int mipLevel = 0,
      int bufferOffset = 0,
      int originX = 0,
      int originY = 0,
      int originZ = 0,
      int? width,
      int? height}) {
    _checkAlive();
    final w = width ?? texture.width;
    final h = height ?? texture.height;
    NitroWebgpu.instance.encoderCopyBufferToTexture(
        _address, source._address, bytesPerRow ?? w * 4, texture._address,
        mipLevel, w, h, bufferOffset, originX, originY, originZ);
  }

  /// Copies a region between two textures — any mip level, any origin
  /// (z = array layer / 3D slice), [depth] slices deep. Defaults to the
  /// source's full mip-0 size.
  void copyTextureToTexture(GpuTexture source, GpuTexture destination,
      {int? width,
      int? height,
      int depth = 1,
      int srcMipLevel = 0,
      int srcX = 0,
      int srcY = 0,
      int srcZ = 0,
      int dstMipLevel = 0,
      int dstX = 0,
      int dstY = 0,
      int dstZ = 0}) {
    _checkAlive();
    NitroWebgpu.instance.encoderCopyTextureToTexture(
        _address,
        source._address,
        destination._address,
        width ?? source.width,
        height ?? source.height,
        depth,
        srcMipLevel,
        srcX,
        srcY,
        srcZ,
        dstMipLevel,
        dstX,
        dstY,
        dstZ);
  }

  /// Copies a region of [texture] (mip [mipLevel], origin x/y/z) into
  /// [destination] at [bufferOffset]. [bytesPerRow] must be a multiple of
  /// 256; defaults to `width * 4` when that meets the alignment.
  void copyTextureToBuffer(GpuTexture texture, GpuBuffer destination,
      {int? bytesPerRow,
      int mipLevel = 0,
      int originX = 0,
      int originY = 0,
      int originZ = 0,
      int bufferOffset = 0,
      int? width,
      int? height}) {
    _checkAlive();
    final w = width ?? texture.width;
    final h = height ?? texture.height;
    NitroWebgpu.instance.encoderCopyTextureToBuffer(
      _address,
      texture._address,
      destination._address,
      bytesPerRow ?? w * 4,
      w,
      h,
      mipLevel,
      originX,
      originY,
      originZ,
      bufferOffset,
    );
  }

  /// Zero-fills [size] bytes of [buffer] at [offset] (null = to the end).
  /// The buffer's usage must include [GpuBufferUsage.copyDst]; offset and
  /// size must be 4-byte aligned.
  void clearBuffer(GpuBuffer buffer, {int offset = 0, int? size}) {
    _checkAlive();
    NitroWebgpu.instance
        .encoderClearBuffer(_address, buffer._address, offset, size ?? -1);
  }

  /// Writes a timestamp into [querySet] outside any pass (device must have
  /// timestamp queries enabled).
  void writeTimestamp(GpuQuerySet querySet, int queryIndex) {
    _checkAlive();
    NitroWebgpu.instance
        .encoderWriteTimestamp(_address, querySet._address, queryIndex);
  }

  /// Debug groups/markers show up in GPU captures (Xcode, RenderDoc).
  void pushDebugGroup(String label) {
    _checkAlive();
    NitroWebgpu.instance.encoderPushDebugGroup(_address, label);
  }

  void popDebugGroup() {
    _checkAlive();
    NitroWebgpu.instance.encoderPopDebugGroup(_address);
  }

  void insertDebugMarker(String label) {
    _checkAlive();
    NitroWebgpu.instance.encoderInsertDebugMarker(_address, label);
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

  void setBindGroup(int index, GpuBindGroup bindGroup,
      {List<int> dynamicOffsets = const []}) {
    _checkAlive();
    if (dynamicOffsets.isEmpty) {
      NitroWebgpu.instance
          .computePassSetBindGroup(_address, index, bindGroup._address);
      return;
    }
    if (dynamicOffsets.length > 8) {
      throw ArgumentError('at most 8 dynamic offsets are supported');
    }
    NitroWebgpu.instance.computePassSetBindGroupOffsets(
      _address,
      index,
      bindGroup._address,
      dynamicOffsets.length,
      dynamicOffsets[0],
      dynamicOffsets.length > 1 ? dynamicOffsets[1] : 0,
      dynamicOffsets.length > 2 ? dynamicOffsets[2] : 0,
      dynamicOffsets.length > 3 ? dynamicOffsets[3] : 0,
      dynamicOffsets.length > 4 ? dynamicOffsets[4] : 0,
      dynamicOffsets.length > 5 ? dynamicOffsets[5] : 0,
      dynamicOffsets.length > 6 ? dynamicOffsets[6] : 0,
      dynamicOffsets.length > 7 ? dynamicOffsets[7] : 0,
    );
  }

  void pushDebugGroup(String label) {
    _checkAlive();
    NitroWebgpu.instance.computePassPushDebugGroup(_address, label);
  }

  void popDebugGroup() {
    _checkAlive();
    NitroWebgpu.instance.computePassPopDebugGroup(_address);
  }

  void insertDebugMarker(String label) {
    _checkAlive();
    NitroWebgpu.instance.computePassInsertDebugMarker(_address, label);
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

  /// Number of mip levels (native-backed).
  int get mipLevelCount {
    _checkAlive();
    return NitroWebgpu.instance.textureGetMipLevelCount(_address);
  }

  /// MSAA sample count (native-backed).
  int get sampleCount {
    _checkAlive();
    return NitroWebgpu.instance.textureGetSampleCount(_address);
  }

  /// Array layer count (2D) / depth (3D), native-backed.
  int get depthOrArrayLayers {
    _checkAlive();
    return NitroWebgpu.instance.textureGetDepthOrArrayLayers(_address);
  }

  /// The texture's dimensionality (native-backed).
  GpuTextureDimension get dimension {
    _checkAlive();
    final raw = NitroWebgpu.instance.textureGetDimension(_address);
    return GpuTextureDimension.values
        .firstWhere((d) => d.raw == raw, orElse: () => GpuTextureDimension.d2);
  }

  /// The usage bitmask the texture was created with (native-backed).
  int get usage {
    _checkAlive();
    return NitroWebgpu.instance.textureGetUsage(_address);
  }

  /// Creates a view. Null counts mean "all remaining"; null [dimension]
  /// infers from the texture (pass [GpuTextureViewDimension.cube] for
  /// cube-sampled 6-layer textures).
  GpuTextureView createView({
    String label = '',
    int baseMipLevel = 0,
    int? mipLevelCount,
    GpuTextureViewDimension? dimension,
    int baseArrayLayer = 0,
    int? arrayLayerCount,
    GpuTextureFormat? format,
  }) {
    _checkAlive();
    final address = NitroWebgpu.instance.textureCreateView(
      _address,
      GpuTextureViewDescriptor(
        label: label,
        baseMipLevel: baseMipLevel,
        mipLevelCount: mipLevelCount ?? 0,
        dimension: dimension?.raw ?? 0,
        baseArrayLayer: baseArrayLayer,
        arrayLayerCount: arrayLayerCount ?? 0,
        format: format?.raw ?? 0,
      ),
    );
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

  /// Set for formats with a stencil aspect (depth24PlusStencil8).
  final GpuLoadOp? stencilLoadOp;
  final GpuStoreOp? stencilStoreOp;
  final int stencilClearValue;

  /// Bind the aspect read-only — load/store ops are ignored and the pass
  /// may sample the attachment.
  final bool depthReadOnly;
  final bool stencilReadOnly;

  const GpuDepthAttachmentInfo({
    required this.view,
    this.loadOp = GpuLoadOp.clear,
    this.storeOp = GpuStoreOp.discard,
    this.clearValue = 1.0,
    this.stencilLoadOp,
    this.stencilStoreOp,
    this.stencilClearValue = 0,
    this.depthReadOnly = false,
    this.stencilReadOnly = false,
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

  void setBindGroup(int index, GpuBindGroup bindGroup,
      {List<int> dynamicOffsets = const []}) {
    _checkAlive();
    if (dynamicOffsets.isEmpty) {
      NitroWebgpu.instance
          .renderPassSetBindGroup(_address, index, bindGroup._address);
      return;
    }
    if (dynamicOffsets.length > 8) {
      throw ArgumentError('at most 8 dynamic offsets are supported');
    }
    NitroWebgpu.instance.renderPassSetBindGroupOffsets(
      _address,
      index,
      bindGroup._address,
      dynamicOffsets.length,
      dynamicOffsets[0],
      dynamicOffsets.length > 1 ? dynamicOffsets[1] : 0,
      dynamicOffsets.length > 2 ? dynamicOffsets[2] : 0,
      dynamicOffsets.length > 3 ? dynamicOffsets[3] : 0,
      dynamicOffsets.length > 4 ? dynamicOffsets[4] : 0,
      dynamicOffsets.length > 5 ? dynamicOffsets[5] : 0,
      dynamicOffsets.length > 6 ? dynamicOffsets[6] : 0,
      dynamicOffsets.length > 7 ? dynamicOffsets[7] : 0,
    );
  }

  void beginOcclusionQuery(int queryIndex) {
    _checkAlive();
    NitroWebgpu.instance.renderPassBeginOcclusionQuery(_address, queryIndex);
  }

  void endOcclusionQuery() {
    _checkAlive();
    NitroWebgpu.instance.renderPassEndOcclusionQuery(_address);
  }

  void setStencilReference(int reference) {
    _checkAlive();
    NitroWebgpu.instance.renderPassSetStencilReference(_address, reference);
  }

  void pushDebugGroup(String label) {
    _checkAlive();
    NitroWebgpu.instance.renderPassPushDebugGroup(_address, label);
  }

  void popDebugGroup() {
    _checkAlive();
    NitroWebgpu.instance.renderPassPopDebugGroup(_address);
  }

  void insertDebugMarker(String label) {
    _checkAlive();
    NitroWebgpu.instance.renderPassInsertDebugMarker(_address, label);
  }

  /// Replays a pre-recorded [GpuRenderBundle].
  void executeBundle(GpuRenderBundle bundle) {
    _checkAlive();
    NitroWebgpu.instance.renderPassExecuteBundle(_address, bundle._address);
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

  /// Whether this is an occlusion or timestamp set (native-backed).
  GpuQueryType get type {
    _checkAlive();
    final raw = NitroWebgpu.instance.querySetGetType(_address);
    return GpuQueryType.values.firstWhere((t) => t.raw == raw);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('GpuQuerySet used after dispose()');
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

/// Records a reusable bundle of render commands (see
/// [GpuDevice.createRenderBundleEncoder]). Call [finish] to produce a
/// [GpuRenderBundle] replayable via `pass.executeBundle`.
class GpuRenderBundleEncoder {
  static final Finalizer<int> _finalizer = Finalizer(
      (address) => NitroWebgpu.instance.renderBundleEncoderRelease(address));

  final int _address;
  bool _disposed = false;

  GpuRenderBundleEncoder._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('GpuRenderBundleEncoder used after finish()');
    }
  }

  void setPipeline(GpuRenderPipeline pipeline) {
    _checkAlive();
    NitroWebgpu.instance.bundleSetPipeline(_address, pipeline._address);
  }

  void setBindGroup(int index, GpuBindGroup bindGroup) {
    _checkAlive();
    NitroWebgpu.instance
        .bundleSetBindGroup(_address, index, bindGroup._address);
  }

  void setVertexBuffer(int slot, GpuBuffer buffer, {int offset = 0}) {
    _checkAlive();
    NitroWebgpu.instance
        .bundleSetVertexBuffer(_address, slot, buffer._address, offset);
  }

  void setIndexBuffer(GpuBuffer buffer, GpuIndexFormat format,
      {int offset = 0}) {
    _checkAlive();
    NitroWebgpu.instance
        .bundleSetIndexBuffer(_address, buffer._address, format.raw, offset);
  }

  void draw(int vertexCount,
      {int instanceCount = 1, int firstVertex = 0, int firstInstance = 0}) {
    _checkAlive();
    NitroWebgpu.instance.bundleDraw(
        _address, vertexCount, instanceCount, firstVertex, firstInstance);
  }

  void drawIndexed(int indexCount,
      {int instanceCount = 1,
      int firstIndex = 0,
      int baseVertex = 0,
      int firstInstance = 0}) {
    _checkAlive();
    NitroWebgpu.instance.bundleDrawIndexed(_address, indexCount,
        instanceCount, firstIndex, baseVertex, firstInstance);
  }

  void drawIndirect(GpuBuffer indirectBuffer, {int offset = 0}) {
    _checkAlive();
    NitroWebgpu.instance
        .bundleDrawIndirect(_address, indirectBuffer._address, offset);
  }

  void drawIndexedIndirect(GpuBuffer indirectBuffer, {int offset = 0}) {
    _checkAlive();
    NitroWebgpu.instance
        .bundleDrawIndexedIndirect(_address, indirectBuffer._address, offset);
  }

  /// Finishes recording; the encoder is consumed.
  GpuRenderBundle finish({String label = ''}) {
    _checkAlive();
    final address = NitroWebgpu.instance.bundleFinish(_address, label);
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.renderBundleEncoderRelease(_address);
    return GpuRenderBundle._(address);
  }

  /// Abandons an unfinished encoder.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.renderBundleEncoderRelease(_address);
  }
}

/// A pre-recorded, replayable bundle of render commands.
class GpuRenderBundle {
  static final Finalizer<int> _finalizer = Finalizer(
      (address) => NitroWebgpu.instance.renderBundleRelease(address));

  final int _address;
  bool _disposed = false;

  GpuRenderBundle._(this._address) {
    _finalizer.attach(this, _address, detach: this);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    NitroWebgpu.instance.renderBundleRelease(_address);
  }
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
