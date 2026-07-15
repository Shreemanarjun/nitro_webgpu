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

/// Buffer usage bits. These ARE the WebGPU spec values (identical to the JS
/// `GPUBufferUsage` constants), so they pass through to wgpu unchanged.
abstract final class GpuBufferUsage {
  static const int mapRead = 1 << 0;
  static const int mapWrite = 1 << 1;
  static const int copySrc = 1 << 2;
  static const int copyDst = 1 << 3;
  static const int index = 1 << 4;
  static const int vertex = 1 << 5;
  static const int uniform = 1 << 6;
  static const int storage = 1 << 7;
  static const int indirect = 1 << 8;
  static const int queryResolve = 1 << 9;
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

  /// Request the `timestamp-query` feature (check
  /// [NitroWebgpu.adapterHasTimestampQuery] first — requesting an
  /// unsupported feature fails device creation).
  final bool requireTimestampQueries;

  const GpuDeviceDescriptor({
    this.label = '',
    this.requireTimestampQueries = false,
  });
}

/// Descriptor for [NitroWebgpu.encoderBeginComputePass].
@hybridRecord
class GpuComputePassDescriptor {
  final String label;

  /// Raw `WGPUQuerySet` address for pass timestamps; 0 = none.
  final int timestampQuerySetAddress;
  final int timestampBeginIndex;
  final int timestampEndIndex;

  const GpuComputePassDescriptor({
    this.label = '',
    this.timestampQuerySetAddress = 0,
    this.timestampBeginIndex = 0,
    this.timestampEndIndex = 1,
  });
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

/// Descriptor for [NitroWebgpu.deviceCreateBuffer].
@hybridRecord
class GpuBufferDescriptor {
  final String label;
  final int size;

  /// Bitmask of [GpuBufferUsage] values.
  final int usage;
  final bool mappedAtCreation;

  const GpuBufferDescriptor({
    this.label = '',
    required this.size,
    required this.usage,
    this.mappedAtCreation = false,
  });
}

/// One resource binding inside a [GpuBindGroupDescriptor]. Exactly one of
/// [bufferAddress], [samplerAddress], or [textureViewAddress] is non-zero.
@hybridRecord
class GpuBindGroupEntry {
  final int binding;

  /// Raw `WGPUBuffer` address; 0 = not a buffer binding.
  final int bufferAddress;
  final int offset;

  /// Byte size of the binding; -1 binds the whole buffer.
  final int size;

  /// Raw `WGPUSampler` address; 0 = not a sampler binding.
  final int samplerAddress;

  /// Raw `WGPUTextureView` address; 0 = not a texture binding.
  final int textureViewAddress;

  const GpuBindGroupEntry({
    required this.binding,
    this.bufferAddress = 0,
    this.offset = 0,
    this.size = -1,
    this.samplerAddress = 0,
    this.textureViewAddress = 0,
  });
}

/// Descriptor for [NitroWebgpu.deviceCreateSampler]. Filter values are raw
/// `WGPUFilterMode` (1 = nearest, 2 = linear); address modes are raw
/// `WGPUAddressMode` (1 = clampToEdge, 2 = repeat, 3 = mirrorRepeat).
@hybridRecord
class GpuSamplerDescriptor {
  final String label;
  final int magFilter;
  final int minFilter;
  final int mipmapFilter;
  final int addressModeU;
  final int addressModeV;
  final int addressModeW;

  const GpuSamplerDescriptor({
    this.label = '',
    this.magFilter = 2,
    this.minFilter = 2,
    this.mipmapFilter = 1,
    this.addressModeU = 1,
    this.addressModeV = 1,
    this.addressModeW = 1,
  });
}

/// Descriptor for [NitroWebgpu.deviceCreateBindGroup].
@hybridRecord
class GpuBindGroupDescriptor {
  final String label;

  /// Raw `WGPUBindGroupLayout` address.
  final int layoutAddress;
  final List<GpuBindGroupEntry> entries;

  const GpuBindGroupDescriptor({
    this.label = '',
    required this.layoutAddress,
    required this.entries,
  });
}

/// Descriptor for [NitroWebgpu.deviceCreateComputePipeline].
@hybridRecord
class GpuComputePipelineDescriptor {
  final String label;

  /// Raw `WGPUPipelineLayout` address; 0 = auto layout.
  final int layoutAddress;

  /// Raw `WGPUShaderModule` address.
  final int moduleAddress;
  final String entryPoint;

  const GpuComputePipelineDescriptor({
    this.label = '',
    this.layoutAddress = 0,
    required this.moduleAddress,
    this.entryPoint = 'main',
  });
}

/// Result of [NitroWebgpu.bufferMapRead] — a copy of the mapped range.
@hybridRecord
class GpuMappedData {
  final Uint8List data;

  const GpuMappedData({required this.data});
}

/// Texture usage bits. These ARE the WebGPU spec values.
abstract final class GpuTextureUsage {
  static const int copySrc = 1 << 0;
  static const int copyDst = 1 << 1;
  static const int textureBinding = 1 << 2;
  static const int storageBinding = 1 << 3;
  static const int renderAttachment = 1 << 4;
}

/// Descriptor for [NitroWebgpu.deviceCreateTexture] (2D textures only for
/// now — the curated layer grows on demand).
@hybridRecord
class GpuTextureDescriptor {
  final String label;
  final int width;
  final int height;

  /// Raw `WGPUTextureFormat` (0x16 = rgba8unorm, 0x1B = bgra8unorm).
  final int format;

  /// Bitmask of [GpuTextureUsage] values.
  final int usage;
  final int mipLevelCount;
  final int sampleCount;

  const GpuTextureDescriptor({
    this.label = '',
    required this.width,
    required this.height,
    required this.format,
    required this.usage,
    this.mipLevelCount = 1,
    this.sampleCount = 1,
  });
}

/// One color attachment of a render pass.
@hybridRecord
class GpuColorAttachment {
  /// Raw `WGPUTextureView` address.
  final int viewAddress;

  /// Raw `WGPULoadOp`: 1 = load, 2 = clear.
  final int loadOp;

  /// Raw `WGPUStoreOp`: 1 = store, 2 = discard.
  final int storeOp;
  final double clearR;
  final double clearG;
  final double clearB;
  final double clearA;

  const GpuColorAttachment({
    required this.viewAddress,
    this.loadOp = 2,
    this.storeOp = 1,
    this.clearR = 0,
    this.clearG = 0,
    this.clearB = 0,
    this.clearA = 1,
  });
}

/// Descriptor for [NitroWebgpu.encoderBeginRenderPass].
@hybridRecord
class GpuRenderPassDescriptor {
  final String label;
  final List<GpuColorAttachment> colorAttachments;

  /// Raw `WGPUQuerySet` address for pass timestamps; 0 = none.
  final int timestampQuerySetAddress;
  final int timestampBeginIndex;
  final int timestampEndIndex;

  /// Raw `WGPUTextureView` address of the depth attachment; 0 = none.
  final int depthViewAddress;

  /// Raw `WGPULoadOp` for depth: 1 = load, 2 = clear.
  final int depthLoadOp;

  /// Raw `WGPUStoreOp` for depth: 1 = store, 2 = discard.
  final int depthStoreOp;
  final double depthClearValue;

  const GpuRenderPassDescriptor({
    this.label = '',
    required this.colorAttachments,
    this.timestampQuerySetAddress = 0,
    this.timestampBeginIndex = 0,
    this.timestampEndIndex = 1,
    this.depthViewAddress = 0,
    this.depthLoadOp = 2,
    this.depthStoreOp = 2,
    this.depthClearValue = 1.0,
  });
}

/// Shader stage visibility bits (spec values, identical to JS
/// `GPUShaderStage`).
abstract final class GpuShaderStage {
  static const int vertex = 1;
  static const int fragment = 2;
  static const int compute = 4;
}

/// One vertex attribute within a [GpuVertexBufferLayout].
@hybridRecord
class GpuVertexAttribute {
  /// Raw `WGPUVertexFormat` (0x1C = float32, 0x1D = float32x2,
  /// 0x1E = float32x3, 0x1F = float32x4, 0x20 = uint32).
  final int format;
  final int offset;
  final int shaderLocation;

  const GpuVertexAttribute({
    required this.format,
    required this.offset,
    required this.shaderLocation,
  });
}

/// One vertex buffer slot's layout.
@hybridRecord
class GpuVertexBufferLayout {
  final int arrayStride;

  /// Raw `WGPUVertexStepMode`: 1 = per-vertex, 2 = per-instance.
  final int stepMode;
  final List<GpuVertexAttribute> attributes;

  const GpuVertexBufferLayout({
    required this.arrayStride,
    this.stepMode = 1,
    required this.attributes,
  });
}

/// One entry of an explicit bind group layout. [type] is curated:
/// 1 = uniform buffer, 2 = storage buffer, 3 = read-only storage buffer,
/// 4 = filtering sampler, 5 = float 2D texture.
@hybridRecord
class GpuBindGroupLayoutEntry {
  final int binding;

  /// Bitmask of [GpuShaderStage] values.
  final int visibility;
  final int type;

  const GpuBindGroupLayoutEntry({
    required this.binding,
    required this.visibility,
    required this.type,
  });
}

/// Descriptor for [NitroWebgpu.deviceCreateBindGroupLayout].
@hybridRecord
class GpuBindGroupLayoutDescriptor {
  final String label;
  final List<GpuBindGroupLayoutEntry> entries;

  const GpuBindGroupLayoutDescriptor({
    this.label = '',
    required this.entries,
  });
}

/// Descriptor for [NitroWebgpu.deviceCreatePipelineLayout]. Up to four bind
/// group layouts (WebGPU's guaranteed minimum); 0 = slot unused. Unused
/// slots must be trailing.
@hybridRecord
class GpuPipelineLayoutDescriptor {
  final String label;
  final int layout0;
  final int layout1;
  final int layout2;
  final int layout3;

  const GpuPipelineLayoutDescriptor({
    this.label = '',
    this.layout0 = 0,
    this.layout1 = 0,
    this.layout2 = 0,
    this.layout3 = 0,
  });
}

/// Curated render pipeline: one shader module, one color target, optional
/// vertex buffers, optional depth, preset blending.
@hybridRecord
class GpuRenderPipelineDescriptor {
  final String label;

  /// Raw `WGPUShaderModule` address (used for both stages).
  final int moduleAddress;
  final String vertexEntryPoint;
  final String fragmentEntryPoint;

  /// Raw `WGPUTextureFormat` of the single color target.
  final int targetFormat;

  /// Raw `WGPUPrimitiveTopology`; 4 = triangle list.
  final int topology;

  /// Vertex buffer slots; empty = geometry from `vertex_index` only.
  final List<GpuVertexBufferLayout> vertexBuffers;

  /// Raw `WGPUPipelineLayout` address; 0 = auto layout.
  final int layoutAddress;

  /// Raw `WGPUTextureFormat` of the depth attachment; 0 = no depth.
  final int depthFormat;
  final bool depthWriteEnabled;

  /// Raw `WGPUCompareFunction`; 2 = less (standard depth test).
  final int depthCompare;

  /// Blend preset: 0 = opaque, 1 = alpha, 2 = additive, 3 = premultiplied.
  final int blendMode;

  const GpuRenderPipelineDescriptor({
    this.label = '',
    required this.moduleAddress,
    this.vertexEntryPoint = 'vs_main',
    this.fragmentEntryPoint = 'fs_main',
    required this.targetFormat,
    this.topology = 4,
    this.vertexBuffers = const [],
    this.layoutAddress = 0,
    this.depthFormat = 0,
    this.depthWriteEnabled = true,
    this.depthCompare = 2,
    this.blendMode = 0,
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

  /// Whether the adapter supports the `timestamp-query` feature.
  bool adapterHasTimestampQuery(int adapter);

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

  // ── Buffers ────────────────────────────────────────────────────────────

  int deviceCreateBuffer(int device, GpuBufferDescriptor descriptor);

  /// WebGPU `buffer.destroy()` — frees GPU memory; handle still needs
  /// [bufferRelease].
  void bufferDestroy(int buffer);
  void bufferRelease(int buffer);
  int bufferGetSize(int buffer);

  /// Copies [data] into the buffer via `wgpuQueueWriteBuffer` (wgpu copies
  /// synchronously — the Dart buffer is not retained).
  void queueWriteBuffer(
      int queue, int buffer, int bufferOffset, @zeroCopy Uint8List data);

  /// Curated mapAsync: maps [size] bytes at [offset] for reading, copies the
  /// range, unmaps, and resolves with the copy. Rejects on map failure.
  @nitroNativeAsync
  Future<GpuMappedData> bufferMapRead(int buffer, int offset, int size);

  // ── Shaders / pipelines / bind groups ──────────────────────────────────

  /// Creates a WGSL shader module. Compile errors surface through error
  /// scopes — use the wrapper's checked create.
  int deviceCreateShaderModuleWgsl(int device, String label, String wgsl);
  void shaderModuleRelease(int module);

  int deviceCreateComputePipeline(
      int device, GpuComputePipelineDescriptor descriptor);
  void computePipelineRelease(int pipeline);

  /// Returns the pipeline's bind group layout (+1 ref; pair with
  /// [bindGroupLayoutRelease]).
  int computePipelineGetBindGroupLayout(int pipeline, int groupIndex);
  void bindGroupLayoutRelease(int layout);

  int deviceCreateBindGroup(int device, GpuBindGroupDescriptor descriptor);
  void bindGroupRelease(int bindGroup);

  // ── Command encoding / submission ──────────────────────────────────────

  int deviceCreateCommandEncoder(int device, String label);
  void commandEncoderRelease(int encoder);

  int encoderBeginComputePass(int encoder, GpuComputePassDescriptor descriptor);
  void computePassSetPipeline(int pass, int pipeline);
  void computePassSetBindGroup(int pass, int index, int bindGroup);
  void computePassDispatchWorkgroups(int pass, int x, int y, int z);
  void computePassEnd(int pass);
  void computePassRelease(int pass);

  void encoderCopyBufferToBuffer(
      int encoder, int src, int srcOffset, int dst, int dstOffset, int size);

  /// Finishes the encoder into a command buffer (encoder becomes invalid but
  /// still needs [commandEncoderRelease]).
  int encoderFinish(int encoder, String label);
  void commandBufferRelease(int commandBuffer);

  void queueSubmitOne(int queue, int commandBuffer);

  /// Resolves when all submitted work on the queue completes.
  @nitroNativeAsync
  Future<void> queueOnSubmittedWorkDone(int queue);

  // ── Textures / render passes ───────────────────────────────────────────

  int deviceCreateTexture(int device, GpuTextureDescriptor descriptor);

  /// WebGPU `texture.destroy()` — frees GPU memory; handle still needs
  /// [textureRelease].
  void textureDestroy(int texture);
  void textureRelease(int texture);

  /// Creates the default full-texture view.
  int textureCreateView(int texture, String label);
  void textureViewRelease(int view);

  /// Copies [data] into mip 0 of a 2D [texture] (usage must include
  /// `GpuTextureUsage.copyDst`). No 256-byte row alignment is required for
  /// writeTexture; [bytesPerRow] is the tight source stride.
  void queueWriteTexture(int queue, int texture, @zeroCopy Uint8List data,
      int bytesPerRow, int width, int height);

  int deviceCreateSampler(int device, GpuSamplerDescriptor descriptor);
  void samplerRelease(int sampler);

  int deviceCreateRenderPipeline(int device, GpuRenderPipelineDescriptor descriptor);
  void renderPipelineRelease(int pipeline);

  /// Returns the render pipeline's bind group layout (+1 ref; pair with
  /// [bindGroupLayoutRelease]).
  int renderPipelineGetBindGroupLayout(int pipeline, int groupIndex);

  // ── Explicit layouts ───────────────────────────────────────────────────

  int deviceCreateBindGroupLayout(
      int device, GpuBindGroupLayoutDescriptor descriptor);
  int deviceCreatePipelineLayout(
      int device, GpuPipelineLayoutDescriptor descriptor);
  void pipelineLayoutRelease(int layout);

  int encoderBeginRenderPass(int encoder, GpuRenderPassDescriptor descriptor);
  void renderPassSetPipeline(int pass, int pipeline);
  void renderPassSetBindGroup(int pass, int index, int bindGroup);

  void renderPassSetVertexBuffer(int pass, int slot, int buffer, int offset);

  /// indexFormat: raw `WGPUIndexFormat` — 1 = uint16, 2 = uint32.
  void renderPassSetIndexBuffer(
      int pass, int buffer, int indexFormat, int offset);

  void renderPassDraw(int pass, int vertexCount, int instanceCount,
      int firstVertex, int firstInstance);
  void renderPassDrawIndexed(int pass, int indexCount, int instanceCount,
      int firstIndex, int baseVertex, int firstInstance);
  void renderPassEnd(int pass);
  void renderPassRelease(int pass);

  /// Copies a full 2D texture (mip 0) into [buffer]. [bytesPerRow] must be a
  /// multiple of 256 per the WebGPU spec.
  void encoderCopyTextureToBuffer(int encoder, int texture, int buffer,
      int bytesPerRow, int width, int height);

  // ── Timestamp queries ──────────────────────────────────────────────────

  /// Creates a timestamp `WGPUQuerySet` with [count] slots. The device must
  /// have been created with `requireTimestampQueries`.
  int deviceCreateTimestampQuerySet(int device, int count);
  void querySetRelease(int querySet);

  /// Resolves query slots into [destination] (usage must include
  /// `GpuBufferUsage.queryResolve`); 8 bytes per slot, raw GPU ticks.
  void encoderResolveQuerySet(int encoder, int querySet, int firstQuery,
      int queryCount, int destination, int destinationOffset);

  /// Nanoseconds per timestamp tick for the queue.
  double queueTimestampPeriod(int queue);
}
