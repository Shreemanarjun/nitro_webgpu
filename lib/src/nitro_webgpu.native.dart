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

/// The full standard `WGPULimits` set.
@hybridRecord
class GpuLimits {
  final int maxTextureDimension1D;
  final int maxTextureDimension2D;
  final int maxTextureDimension3D;
  final int maxTextureArrayLayers;
  final int maxBindGroups;
  final int maxBindGroupsPlusVertexBuffers;
  final int maxBindingsPerBindGroup;
  final int maxDynamicUniformBuffersPerPipelineLayout;
  final int maxDynamicStorageBuffersPerPipelineLayout;
  final int maxSampledTexturesPerShaderStage;
  final int maxSamplersPerShaderStage;
  final int maxStorageBuffersPerShaderStage;
  final int maxStorageTexturesPerShaderStage;
  final int maxUniformBuffersPerShaderStage;
  final int maxUniformBufferBindingSize;
  final int maxStorageBufferBindingSize;
  final int minUniformBufferOffsetAlignment;
  final int minStorageBufferOffsetAlignment;
  final int maxVertexBuffers;
  final int maxBufferSize;
  final int maxVertexAttributes;
  final int maxVertexBufferArrayStride;
  final int maxInterStageShaderVariables;
  final int maxColorAttachments;
  final int maxColorAttachmentBytesPerSample;
  final int maxComputeWorkgroupStorageSize;
  final int maxComputeInvocationsPerWorkgroup;
  final int maxComputeWorkgroupSizeX;
  final int maxComputeWorkgroupSizeY;
  final int maxComputeWorkgroupSizeZ;
  final int maxComputeWorkgroupsPerDimension;

  const GpuLimits({
    required this.maxTextureDimension1D,
    required this.maxTextureDimension2D,
    required this.maxTextureDimension3D,
    required this.maxTextureArrayLayers,
    required this.maxBindGroups,
    required this.maxBindGroupsPlusVertexBuffers,
    required this.maxBindingsPerBindGroup,
    required this.maxDynamicUniformBuffersPerPipelineLayout,
    required this.maxDynamicStorageBuffersPerPipelineLayout,
    required this.maxSampledTexturesPerShaderStage,
    required this.maxSamplersPerShaderStage,
    required this.maxStorageBuffersPerShaderStage,
    required this.maxStorageTexturesPerShaderStage,
    required this.maxUniformBuffersPerShaderStage,
    required this.maxUniformBufferBindingSize,
    required this.maxStorageBufferBindingSize,
    required this.minUniformBufferOffsetAlignment,
    required this.minStorageBufferOffsetAlignment,
    required this.maxVertexBuffers,
    required this.maxBufferSize,
    required this.maxVertexAttributes,
    required this.maxVertexBufferArrayStride,
    required this.maxInterStageShaderVariables,
    required this.maxColorAttachments,
    required this.maxColorAttachmentBytesPerSample,
    required this.maxComputeWorkgroupStorageSize,
    required this.maxComputeInvocationsPerWorkgroup,
    required this.maxComputeWorkgroupSizeX,
    required this.maxComputeWorkgroupSizeY,
    required this.maxComputeWorkgroupSizeZ,
    required this.maxComputeWorkgroupsPerDimension,
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

  /// Limit overrides; null keeps every limit at its default.
  final GpuRequiredLimits? requiredLimits;

  /// Feature bitmask: bit `i` set requests raw `WGPUFeatureName` value `i`
  /// (see [NitroWebgpu.adapterGetFeatures]). 0 = no extra features.
  final int requiredFeatures;

  const GpuDeviceDescriptor({
    this.label = '',
    this.requireTimestampQueries = false,
    this.requiredLimits,
    this.requiredFeatures = 0,
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

  /// Raw `WGPUCompareFunction`; non-zero makes this a comparison sampler
  /// (WGSL `sampler_comparison`, for shadow mapping).
  final int compare;
  final double lodMinClamp;
  final double lodMaxClamp;

  /// >1 enables anisotropic filtering (all filters must be linear).
  final int maxAnisotropy;

  const GpuSamplerDescriptor({
    this.label = '',
    this.magFilter = 2,
    this.minFilter = 2,
    this.mipmapFilter = 1,
    this.addressModeU = 1,
    this.addressModeV = 1,
    this.addressModeW = 1,
    this.compare = 0,
    this.lodMinClamp = 0.0,
    this.lodMaxClamp = 32.0,
    this.maxAnisotropy = 1,
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

  /// Raw `WGPUTextureDimension`: 1 = 1D, 2 = 2D, 3 = 3D.
  final int dimension;

  /// Depth for 3D textures / array layer count for 2D (6 for cubes).
  final int depthOrArrayLayers;

  /// Extra raw format views may reinterpret this texture as (e.g. the srgb
  /// variant); 0 = none.
  final int viewFormat;

  const GpuTextureDescriptor({
    this.label = '',
    required this.width,
    required this.height,
    required this.format,
    required this.usage,
    this.mipLevelCount = 1,
    this.sampleCount = 1,
    this.dimension = 2,
    this.depthOrArrayLayers = 1,
    this.viewFormat = 0,
  });
}

/// Descriptor for [NitroWebgpu.textureCreateView]. Zeros mean "default/all".
@hybridRecord
class GpuTextureViewDescriptor {
  final String label;
  final int baseMipLevel;

  /// 0 = all remaining mip levels.
  final int mipLevelCount;

  /// Raw `WGPUTextureViewDimension`: 0 = infer, 1 = 1D, 2 = 2D,
  /// 3 = 2D-array, 4 = cube, 5 = cube-array, 6 = 3D.
  final int dimension;
  final int baseArrayLayer;

  /// 0 = all remaining array layers.
  final int arrayLayerCount;

  /// Raw `WGPUTextureFormat` reinterpretation (must be listed as the
  /// texture's viewFormat); 0 = the texture's own format.
  final int format;

  const GpuTextureViewDescriptor({
    this.label = '',
    this.baseMipLevel = 0,
    this.mipLevelCount = 0,
    this.dimension = 0,
    this.baseArrayLayer = 0,
    this.arrayLayerCount = 0,
    this.format = 0,
  });
}

/// Requested device limits; -1 leaves a limit at its default.
@hybridRecord
class GpuRequiredLimits {
  final int maxTextureDimension1D;
  final int maxTextureDimension2D;
  final int maxTextureDimension3D;
  final int maxTextureArrayLayers;
  final int maxBindGroups;
  final int maxBindGroupsPlusVertexBuffers;
  final int maxBindingsPerBindGroup;
  final int maxDynamicUniformBuffersPerPipelineLayout;
  final int maxDynamicStorageBuffersPerPipelineLayout;
  final int maxSampledTexturesPerShaderStage;
  final int maxSamplersPerShaderStage;
  final int maxStorageBuffersPerShaderStage;
  final int maxStorageTexturesPerShaderStage;
  final int maxUniformBuffersPerShaderStage;
  final int maxUniformBufferBindingSize;
  final int maxStorageBufferBindingSize;
  final int minUniformBufferOffsetAlignment;
  final int minStorageBufferOffsetAlignment;
  final int maxVertexBuffers;
  final int maxBufferSize;
  final int maxVertexAttributes;
  final int maxVertexBufferArrayStride;
  final int maxInterStageShaderVariables;
  final int maxColorAttachments;
  final int maxColorAttachmentBytesPerSample;
  final int maxComputeWorkgroupStorageSize;
  final int maxComputeInvocationsPerWorkgroup;
  final int maxComputeWorkgroupSizeX;
  final int maxComputeWorkgroupSizeY;
  final int maxComputeWorkgroupSizeZ;
  final int maxComputeWorkgroupsPerDimension;

  const GpuRequiredLimits({
    this.maxTextureDimension1D = -1,
    this.maxTextureDimension2D = -1,
    this.maxTextureDimension3D = -1,
    this.maxTextureArrayLayers = -1,
    this.maxBindGroups = -1,
    this.maxBindGroupsPlusVertexBuffers = -1,
    this.maxBindingsPerBindGroup = -1,
    this.maxDynamicUniformBuffersPerPipelineLayout = -1,
    this.maxDynamicStorageBuffersPerPipelineLayout = -1,
    this.maxSampledTexturesPerShaderStage = -1,
    this.maxSamplersPerShaderStage = -1,
    this.maxStorageBuffersPerShaderStage = -1,
    this.maxStorageTexturesPerShaderStage = -1,
    this.maxUniformBuffersPerShaderStage = -1,
    this.maxUniformBufferBindingSize = -1,
    this.maxStorageBufferBindingSize = -1,
    this.minUniformBufferOffsetAlignment = -1,
    this.minStorageBufferOffsetAlignment = -1,
    this.maxVertexBuffers = -1,
    this.maxBufferSize = -1,
    this.maxVertexAttributes = -1,
    this.maxVertexBufferArrayStride = -1,
    this.maxInterStageShaderVariables = -1,
    this.maxColorAttachments = -1,
    this.maxColorAttachmentBytesPerSample = -1,
    this.maxComputeWorkgroupStorageSize = -1,
    this.maxComputeInvocationsPerWorkgroup = -1,
    this.maxComputeWorkgroupSizeX = -1,
    this.maxComputeWorkgroupSizeY = -1,
    this.maxComputeWorkgroupSizeZ = -1,
    this.maxComputeWorkgroupsPerDimension = -1,
  });
}

/// Descriptor for [NitroWebgpu.deviceCreateRenderBundleEncoder]. Color
/// formats are raw `WGPUTextureFormat`; 0 = slot unused (trailing only).
@hybridRecord
class GpuRenderBundleEncoderDescriptor {
  final String label;
  final int format0;
  final int format1;
  final int format2;
  final int format3;
  final int format4;
  final int format5;
  final int format6;
  final int format7;
  final int depthFormat;
  final int sampleCount;
  final bool depthReadOnly;
  final bool stencilReadOnly;

  const GpuRenderBundleEncoderDescriptor({
    this.label = '',
    required this.format0,
    this.format1 = 0,
    this.format2 = 0,
    this.format3 = 0,
    this.format4 = 0,
    this.format5 = 0,
    this.format6 = 0,
    this.format7 = 0,
    this.depthFormat = 0,
    this.sampleCount = 1,
    this.depthReadOnly = false,
    this.stencilReadOnly = false,
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

  /// Raw `WGPUTextureView` address of the MSAA resolve target; 0 = none.
  final int resolveTargetAddress;

  const GpuColorAttachment({
    required this.viewAddress,
    this.loadOp = 2,
    this.storeOp = 1,
    this.clearR = 0,
    this.clearG = 0,
    this.clearB = 0,
    this.clearA = 1,
    this.resolveTargetAddress = 0,
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

  /// Raw stencil load/store ops; 0 = format has no stencil aspect.
  final int stencilLoadOp;
  final int stencilStoreOp;
  final int stencilClearValue;

  /// Raw `WGPUQuerySet` (occlusion type) address; 0 = none.
  final int occlusionQuerySetAddress;

  /// Bind the depth/stencil aspect read-only (its load/store ops are then
  /// ignored and the pass may sample the attachment).
  final bool depthReadOnly;
  final bool stencilReadOnly;

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
    this.stencilLoadOp = 0,
    this.stencilStoreOp = 0,
    this.stencilClearValue = 0,
    this.occlusionQuerySetAddress = 0,
    this.depthReadOnly = false,
    this.stencilReadOnly = false,
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

  /// For texture entries (type 5): raw `WGPUTextureViewDimension`.
  final int viewDimension;

  /// For buffer entries (types 1–3): bind with dynamic offsets.
  final bool hasDynamicOffset;

  /// For texture entries (type 5): raw `WGPUTextureSampleType` —
  /// 2 = float, 3 = unfilterable-float, 4 = depth, 5 = sint, 6 = uint.
  final int sampleType;

  /// For texture entries (type 5): bind `texture_multisampled_2d`.
  final bool multisampled;

  /// For sampler entries (type 4): raw `WGPUSamplerBindingType` —
  /// 2 = filtering, 3 = non-filtering, 4 = comparison.
  final int samplerType;

  const GpuBindGroupLayoutEntry({
    required this.binding,
    required this.visibility,
    required this.type,
    this.viewDimension = 2,
    this.hasDynamicOffset = false,
    this.sampleType = 2,
    this.multisampled = false,
    this.samplerType = 2,
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

/// Descriptor for [NitroWebgpu.deviceCreatePipelineLayout]. Up to eight
/// bind group layouts (devices past the default `maxBindGroups` of 4 need
/// a matching `requiredLimits`); 0 = slot unused. Unused slots must be
/// trailing.
@hybridRecord
class GpuPipelineLayoutDescriptor {
  final String label;
  final int layout0;
  final int layout1;
  final int layout2;
  final int layout3;
  final int layout4;
  final int layout5;
  final int layout6;
  final int layout7;

  const GpuPipelineLayoutDescriptor({
    this.label = '',
    this.layout0 = 0,
    this.layout1 = 0,
    this.layout2 = 0,
    this.layout3 = 0,
    this.layout4 = 0,
    this.layout5 = 0,
    this.layout6 = 0,
    this.layout7 = 0,
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
  /// Applies to the first color target.
  final int blendMode;

  /// MSAA sample count (1 or 4). Attachments must match.
  final int sampleCount;

  /// Extra color target formats (raw); 0 = unused (trailing only). Up to
  /// eight targets total (the WebGPU default `maxColorAttachments`).
  final int targetFormat1;
  final int targetFormat2;
  final int targetFormat3;
  final int targetFormat4;
  final int targetFormat5;
  final int targetFormat6;
  final int targetFormat7;

  /// Raw `WGPUCompareFunction` for stencil (8 = always). Both faces.
  final int stencilCompare;

  /// Raw `WGPUStencilOperation` (1 = keep, 3 = replace). Both faces
  /// unless the stencilBack* overrides are set.
  final int stencilFailOp;
  final int stencilDepthFailOp;
  final int stencilPassOp;

  /// Raw `WGPUCullMode`: 0/1 = none, 2 = front, 3 = back.
  final int cullMode;

  /// Raw `WGPUFrontFace`: 0/1 = counter-clockwise, 2 = clockwise.
  final int frontFace;

  /// Raw `WGPUIndexFormat` for strip topologies; 0 = undefined.
  final int stripIndexFormat;

  /// Constant depth bias added to each fragment (shadow-map acne fix).
  final int depthBias;
  final double depthBiasSlopeScale;
  final double depthBiasClamp;

  /// Stencil aspect masks; -1 = all bits (0xFFFFFFFF).
  final int stencilReadMask;
  final int stencilWriteMask;

  /// Back-face stencil overrides; compare 0 = mirror the front face state.
  final int stencilBackCompare;
  final int stencilBackFailOp;
  final int stencilBackDepthFailOp;
  final int stencilBackPassOp;

  /// Custom blend (raw `WGPUBlendOperation`/`WGPUBlendFactor`). A non-zero
  /// [colorBlendOp] overrides [blendMode] and applies to every color target.
  final int colorBlendOp;
  final int colorBlendSrc;
  final int colorBlendDst;
  final int alphaBlendOp;
  final int alphaBlendSrc;
  final int alphaBlendDst;

  /// Color write mask bits (r=1, g=2, b=4, a=8); -1 = all channels.
  /// Applies to every color target.
  final int writeMask;

  /// Multisample coverage mask; -1 = all samples.
  final int multisampleMask;

  /// Derive MSAA coverage from fragment alpha (needs sampleCount > 1).
  final bool alphaToCoverageEnabled;

  /// Optional separate fragment-stage module address; 0 = use
  /// [moduleAddress] for both stages. Lets a single-stage GLSL fragment
  /// module pair with a WGSL vertex module.
  final int fragmentModuleAddress;

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
    this.sampleCount = 1,
    this.targetFormat1 = 0,
    this.targetFormat2 = 0,
    this.targetFormat3 = 0,
    this.targetFormat4 = 0,
    this.targetFormat5 = 0,
    this.targetFormat6 = 0,
    this.targetFormat7 = 0,
    this.stencilCompare = 8,
    this.stencilFailOp = 1,
    this.stencilDepthFailOp = 1,
    this.stencilPassOp = 1,
    this.cullMode = 0,
    this.frontFace = 0,
    this.stripIndexFormat = 0,
    this.depthBias = 0,
    this.depthBiasSlopeScale = 0.0,
    this.depthBiasClamp = 0.0,
    this.stencilReadMask = -1,
    this.stencilWriteMask = -1,
    this.stencilBackCompare = 0,
    this.stencilBackFailOp = 0,
    this.stencilBackDepthFailOp = 0,
    this.stencilBackPassOp = 0,
    this.colorBlendOp = 0,
    this.colorBlendSrc = 0,
    this.colorBlendDst = 0,
    this.alphaBlendOp = 0,
    this.alphaBlendSrc = 0,
    this.alphaBlendDst = 0,
    this.writeMask = -1,
    this.multisampleMask = -1,
    this.alphaToCoverageEnabled = false,
    this.fragmentModuleAddress = 0,
  });
}

/// One diagnostic from [NitroWebgpu.shaderModuleGetCompilationInfo].
@hybridRecord
class GpuCompilationMessage {
  final String message;

  /// Raw `WGPUCompilationMessageType`: 1 = error, 2 = warning, 3 = info.
  final int type;

  /// 1-based source position (0 when not applicable).
  final int lineNum;
  final int linePos;

  /// UTF-8 byte offset/length of the span the message covers.
  final int offset;
  final int length;

  const GpuCompilationMessage({
    required this.message,
    required this.type,
    this.lineNum = 0,
    this.linePos = 0,
    this.offset = 0,
    this.length = 0,
  });
}

/// Structured shader diagnostics.
@hybridRecord
class GpuCompilationInfo {
  final List<GpuCompilationMessage> messages;

  const GpuCompilationInfo({required this.messages});
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

  /// Bitmask of supported standard features: bit `i` set = raw
  /// `WGPUFeatureName` value `i` is supported.
  int adapterGetFeatures(int adapter);

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

  /// Bitmask of features the device was created with (same encoding as
  /// [adapterGetFeatures]).
  int deviceGetFeatures(int device);

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

  /// Maps [size] bytes at [offset] for writing (usage needs
  /// `GpuBufferUsage.mapWrite`). The buffer stays mapped until
  /// [bufferUnmap]; write into it with [bufferWriteMapped].
  @nitroNativeAsync
  Future<void> bufferMapWrite(int buffer, int offset, int size);

  /// Copies [data] directly into the mapped range at [offset] (zero
  /// intermediate copies — the Dart buffer is written straight into mapped
  /// GPU memory). The buffer must be mapped (mappedAtCreation or
  /// [bufferMapWrite]).
  void bufferWriteMapped(int buffer, int offset, @zeroCopy Uint8List data);

  /// Unmaps a mapped buffer, making it usable on the GPU again.
  void bufferUnmap(int buffer);

  // ── Introspection (note: wgpuBufferGetMapState is an upstream todo!()
  //    stub in v29 — map state is tracked in the Dart wrapper instead) ────

  /// The buffer's usage bitmask as created.
  int bufferGetUsage(int buffer);

  // ── Shaders / pipelines / bind groups ──────────────────────────────────

  /// Creates a WGSL shader module. Compile errors surface through error
  /// scopes — use the wrapper's checked create.
  int deviceCreateShaderModuleWgsl(int device, String label, String wgsl);
  void shaderModuleRelease(int module);

  /// Structured compile diagnostics (line/column/span per message).
  @nitroNativeAsync
  Future<GpuCompilationInfo> shaderModuleGetCompilationInfo(int module);

  // ── Off-thread creates ───────────────────────────────────────────────
  // wgpu's CreatePipelineAsync is an unimplemented stub upstream, and the
  // sync creates run naga + the driver's shader compiler — hundreds of ms
  // for big shaders on mobile GPUs. These variants run the same sync call
  // on a background thread so the Dart/UI isolate never blocks.

  @nitroNativeAsync
  Future<int> deviceCreateShaderModuleWgslAsync(
      int device, String label, String wgsl);

  /// GLSL ingestion via the wgpu-native `WGPUShaderSourceGLSL` extra
  /// (naga glsl-in — probe-verified in the release binaries). GLSL modules
  /// carry exactly one stage; [stage] is a `GpuShaderStage` bit and the
  /// module's entry point is always `main`.
  @nitroNativeAsync
  Future<int> deviceCreateShaderModuleGlslAsync(
      int device, String label, String glsl, int stage);

  @nitroNativeAsync
  Future<int> deviceCreateRenderPipelineAsync(
      int device, GpuRenderPipelineDescriptor descriptor);

  @nitroNativeAsync
  Future<int> deviceCreateComputePipelineAsync(
      int device, GpuComputePipelineDescriptor descriptor);

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

  /// Zero-fills [size] bytes of [buffer] at [offset]; -1 = to the end.
  void encoderClearBuffer(int encoder, int buffer, int offset, int size);

  /// Writes a timestamp outside a pass (device needs timestamp queries).
  void encoderWriteTimestamp(int encoder, int querySet, int queryIndex);

  // ── Debug groups / markers (show up in GPU captures) ───────────────────

  void encoderPushDebugGroup(int encoder, String label);
  void encoderPopDebugGroup(int encoder);
  void encoderInsertDebugMarker(int encoder, String label);
  void renderPassPushDebugGroup(int pass, String label);
  void renderPassPopDebugGroup(int pass);
  void renderPassInsertDebugMarker(int pass, String label);
  void computePassPushDebugGroup(int pass, String label);
  void computePassPopDebugGroup(int pass);
  void computePassInsertDebugMarker(int pass, String label);

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

  int textureCreateView(int texture, GpuTextureViewDescriptor descriptor);
  void textureViewRelease(int view);

  int textureGetWidth(int texture);
  int textureGetHeight(int texture);
  int textureGetDepthOrArrayLayers(int texture);

  /// Raw `WGPUTextureFormat`.
  int textureGetFormat(int texture);

  /// Raw `WGPUTextureDimension` as stored (0 when created via a defaulted
  /// descriptor — this plugin always passes it explicitly).
  int textureGetDimension(int texture);
  int textureGetMipLevelCount(int texture);
  int textureGetSampleCount(int texture);
  int textureGetUsage(int texture);

  /// Copies [data] into mip [mipLevel] of [texture] at origin
  /// ([originX], [originY], [arrayLayer]) — usage must include
  /// `GpuTextureUsage.copyDst`. No 256-byte row alignment is required for
  /// writeTexture; [bytesPerRow] is the tight source stride.
  void queueWriteTexture(int queue, int texture, @zeroCopy Uint8List data,
      int bytesPerRow, int width, int height, int mipLevel, int arrayLayer,
      int originX, int originY);

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

  /// Copies a [width]×[height] region of [texture] (mip [mipLevel], origin
  /// x/y/z) into [buffer] at [bufferOffset]. [bytesPerRow] must be a
  /// multiple of 256 per the WebGPU spec.
  void encoderCopyTextureToBuffer(int encoder, int texture, int buffer,
      int bytesPerRow, int width, int height, int mipLevel, int originX,
      int originY, int originZ, int bufferOffset);

  /// Copies [buffer] contents at [bufferOffset] into mip [mipLevel] of
  /// [texture] at origin x/y/z. [bytesPerRow] must be a multiple of 256.
  void encoderCopyBufferToTexture(int encoder, int buffer, int bytesPerRow,
      int texture, int mipLevel, int width, int height, int bufferOffset,
      int originX, int originY, int originZ);

  /// Copies a [width]×[height]×[depth] region between two textures at
  /// per-side mips and origins (z = array layer or 3D depth slice).
  void encoderCopyTextureToTexture(int encoder, int srcTexture,
      int dstTexture, int width, int height, int depth, int srcMip, int srcX,
      int srcY, int srcZ, int dstMip, int dstX, int dstY, int dstZ);

  // ── Render pass state ──────────────────────────────────────────────────

  void renderPassSetViewport(int pass, double x, double y, double width,
      double height, double minDepth, double maxDepth);
  void renderPassSetScissorRect(
      int pass, int x, int y, int width, int height);
  void renderPassSetBlendConstant(
      int pass, double r, double g, double b, double a);

  // ── Indirect execution ─────────────────────────────────────────────────

  /// [buffer] holds `[vertexCount, instanceCount, firstVertex,
  /// firstInstance]` as u32 at [offset]; usage needs
  /// `GpuBufferUsage.indirect`.
  void renderPassDrawIndirect(int pass, int buffer, int offset);

  /// [buffer] holds `[indexCount, instanceCount, firstIndex, baseVertex,
  /// firstInstance]` as u32/i32 at [offset].
  void renderPassDrawIndexedIndirect(int pass, int buffer, int offset);

  /// [buffer] holds `[x, y, z]` workgroup counts as u32 at [offset].
  void computePassDispatchWorkgroupsIndirect(int pass, int buffer, int offset);

  // ── Occlusion queries / stencil / dynamic offsets ──────────────────────

  /// Creates an occlusion `WGPUQuerySet` with [count] slots.
  int deviceCreateOcclusionQuerySet(int device, int count);

  /// The device's actual limits (after requiredLimits were applied).
  GpuLimits deviceGetLimits(int device);

  void renderPassBeginOcclusionQuery(int pass, int queryIndex);
  void renderPassEndOcclusionQuery(int pass);
  void renderPassSetStencilReference(int pass, int reference);

  /// setBindGroup with up to eight dynamic offsets (count = how many apply).
  void renderPassSetBindGroupOffsets(int pass, int index, int bindGroup,
      int offsetCount, int o0, int o1, int o2, int o3, int o4, int o5,
      int o6, int o7);
  void computePassSetBindGroupOffsets(int pass, int index, int bindGroup,
      int offsetCount, int o0, int o1, int o2, int o3, int o4, int o5,
      int o6, int o7);

  // ── Render bundles ─────────────────────────────────────────────────────

  int deviceCreateRenderBundleEncoder(
      int device, GpuRenderBundleEncoderDescriptor descriptor);
  void bundleSetPipeline(int bundleEncoder, int pipeline);
  void bundleSetBindGroup(int bundleEncoder, int index, int bindGroup);
  void bundleSetVertexBuffer(
      int bundleEncoder, int slot, int buffer, int offset);
  void bundleSetIndexBuffer(
      int bundleEncoder, int buffer, int indexFormat, int offset);
  void bundleDraw(int bundleEncoder, int vertexCount, int instanceCount,
      int firstVertex, int firstInstance);
  void bundleDrawIndexed(int bundleEncoder, int indexCount, int instanceCount,
      int firstIndex, int baseVertex, int firstInstance);

  /// Indirect draws inside bundles (same arg layouts as the pass variants).
  void bundleDrawIndirect(int bundleEncoder, int buffer, int offset);
  void bundleDrawIndexedIndirect(int bundleEncoder, int buffer, int offset);

  /// Finishes recording; the encoder is invalid afterwards (still release it).
  int bundleFinish(int bundleEncoder, String label);
  void renderBundleEncoderRelease(int bundleEncoder);
  void renderBundleRelease(int bundle);
  void renderPassExecuteBundle(int pass, int bundle);

  // ── Timestamp queries ──────────────────────────────────────────────────

  /// Creates a timestamp `WGPUQuerySet` with [count] slots. The device must
  /// have been created with `requireTimestampQueries`.
  int deviceCreateTimestampQuerySet(int device, int count);
  void querySetRelease(int querySet);

  int querySetGetCount(int querySet);

  /// Raw `WGPUQueryType`: 1 = occlusion, 2 = timestamp.
  int querySetGetType(int querySet);

  /// Resolves query slots into [destination] (usage must include
  /// `GpuBufferUsage.queryResolve`); 8 bytes per slot, raw GPU ticks.
  void encoderResolveQuerySet(int encoder, int querySet, int firstQuery,
      int queryCount, int destination, int destinationOffset);

  /// Nanoseconds per timestamp tick for the queue.
  double queueTimestampPeriod(int queue);
}
