// Backend seam: the ONLY translation unit surface allowed to use
// implementation-specific WebGPU API (wgpu-native's wgpu.h extensions or
// Dawn's dawn/webgpu.h extras). Everything else codes against standard
// webgpu.h plus these nwBackend* helpers.
//
// NITRO_WEBGPU_BACKEND_DAWN selects Dawn; default is wgpu-native. The Dawn
// side is being brought up on feat/dawn-backend (docs/DAWN_MIGRATION.md).
#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#if defined(NITRO_WEBGPU_BACKEND_DAWN)
#include "webgpu/webgpu.h"  // Dawn's generated header

#if defined(NITRO_WEBGPU_HAS_GLSLANG)
#include <glslang/Include/glslang_c_interface.h>
#include <glslang/Public/resource_limits_c.h>
#endif
#else
#include "third_party/wgpu_native/include/webgpu/webgpu.h"
#include "third_party/wgpu_native/include/webgpu/wgpu.h"
#endif

// ── Logging ────────────────────────────────────────────────────────────────
// wgpu-native: process-wide log callback. Dawn: logging is per-device
// (WGPULoggingCallbackInfo in the device descriptor) — the instance-level
// hook is a no-op there and devices wire their own callback.
using NwBackendLogFn = void (*)(int level, const char* message, size_t length);

inline void nwBackendInitLogging([[maybe_unused]] NwBackendLogFn fn) {
#if !defined(NITRO_WEBGPU_BACKEND_DAWN)
    static NwBackendLogFn gLogFn = nullptr;
    gLogFn = fn;
    wgpuSetLogLevel(WGPULogLevel_Warn);
    wgpuSetLogCallback(
        [](WGPULogLevel level, WGPUStringView message, void*) {
            if (gLogFn) gLogFn((int)level, message.data, message.length);
        },
        nullptr);
#endif
}

// ── Instance descriptor ────────────────────────────────────────────────────
// wgpu-native: WGPUInstanceExtras.backends chained onto the instance
// descriptor restricts which backends probe. Dawn: no instance-level mask —
// backend preference is expressed per requestAdapter; the chain stays empty.
struct NwBackendInstanceDesc {
    WGPUInstanceDescriptor desc = {};
#if defined(NITRO_WEBGPU_BACKEND_DAWN)
    WGPUDawnTogglesDescriptor toggles = {};
#else
    WGPUInstanceExtras extras = {};
#endif
};

inline void nwBackendFillInstanceDesc(NwBackendInstanceDesc* d,
                                      uint64_t backendBits) {
    d->desc = {};
#if defined(NITRO_WEBGPU_BACKEND_DAWN)
    (void)backendBits;
    // Dawn devices are NOT thread-safe by default (wgpu-native's Rust core
    // is): the plugin calls into wgpu from the Dart thread, the callback
    // pump, and the creation worker, so implicit synchronization is
    // required — without it, cross-thread error-scope state silently
    // misbehaves. allow_unsafe_apis unlocks SPIR-V module ingestion for
    // the GLSL (glslang→SPIR-V) path; the plugin validates inputs itself.
    static const char* const kToggles[] = {
        "allow_unsafe_apis",
    };
    d->toggles = {};
    d->toggles.chain.sType = WGPUSType_DawnTogglesDescriptor;
    d->toggles.enabledToggleCount = 1;
    d->toggles.enabledToggles = kToggles;
    d->desc.nextInChain = &d->toggles.chain;
    // ShaderSourceSPIRV: SPIR-V module ingestion (the GLSL→glslang path),
    // additionally gated on the Tint SPIR-V reader being built
    // (-DTINT_BUILD_SPV_READER=ON, see scripts/stage_dawn_macos.sh).
    // MultipleDevicesPerAdapter: wgpu-native never "consumes" an adapter —
    // apps legitimately create several devices from one adapter, so match
    // that behavior for 1:1 parity.
    static const WGPUInstanceFeatureName kInstanceFeatures[] = {
        WGPUInstanceFeatureName_ShaderSourceSPIRV,
        WGPUInstanceFeatureName_MultipleDevicesPerAdapter,
    };
    d->desc.requiredFeatureCount = 2;
    d->desc.requiredFeatures = kInstanceFeatures;
#else
    d->extras = {};
    d->extras.chain.sType = static_cast<WGPUSType>(WGPUSType_InstanceExtras);
    d->extras.backends = static_cast<WGPUInstanceBackend>(backendBits);
    d->desc.nextInChain = &d->extras.chain;
#endif
}

// ── Adapter enumeration ────────────────────────────────────────────────────
// wgpu-native: true enumeration. Dawn: no C-API enumeration — returns false
// and the caller falls back to wgpuInstanceRequestAdapter (which on Dawn can
// be steered per-backend via WGPURequestAdapterOptions).
inline bool nwBackendEnumerateAdapters(WGPUInstance instance,
                                       std::vector<WGPUAdapter>* out) {
#if defined(NITRO_WEBGPU_BACKEND_DAWN)
    // Dawn has no C-API enumeration: request one adapter per backend type
    // and collect the ones that resolve. Callbacks are AllowProcessEvents,
    // pumped inline — this runs on the Dart thread during requestAdapter,
    // before any async ops are in flight.
    static const WGPUBackendType kBackends[] = {
        WGPUBackendType_Metal,  WGPUBackendType_Vulkan,
        WGPUBackendType_D3D12,  WGPUBackendType_D3D11,
        WGPUBackendType_OpenGLES,
    };
    for (WGPUBackendType backend : kBackends) {
        struct Result {
            WGPUAdapter adapter = nullptr;
            bool done = false;
        } result;
        WGPURequestAdapterOptions opts = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
        opts.backendType = backend;
        WGPURequestAdapterCallbackInfo cb =
            WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
        cb.mode = WGPUCallbackMode_AllowProcessEvents;
        cb.userdata1 = &result;
        cb.callback = [](WGPURequestAdapterStatus status, WGPUAdapter adapter,
                         WGPUStringView, void* ud1, void*) {
            auto* r = static_cast<Result*>(ud1);
            if (status == WGPURequestAdapterStatus_Success) {
                r->adapter = adapter;
            } else if (adapter) {
                wgpuAdapterRelease(adapter);
            }
            r->done = true;
        };
        wgpuInstanceRequestAdapter(instance, &opts, cb);
        for (int i = 0; i < 1000 && !result.done; i++) {
            wgpuInstanceProcessEvents(instance);
            if (!result.done) std::this_thread::yield();
        }
        if (result.adapter) out->push_back(result.adapter);
    }
    return !out->empty();
#else
    size_t count = wgpuInstanceEnumerateAdapters(instance, nullptr, nullptr);
    if (count == 0) return false;
    out->resize(count);
    count = wgpuInstanceEnumerateAdapters(instance, nullptr, out->data());
    out->resize(count);
    return true;
#endif
}

// ── Device progress ────────────────────────────────────────────────────────
// The pump calls this per registered device so mapAsync/workdone callbacks
// fire. wgpu-native: wgpuDevicePoll(wait=false). Dawn: wgpuDeviceTick.
inline void nwBackendDevicePoll(WGPUDevice device) {
#if defined(NITRO_WEBGPU_BACKEND_DAWN)
    wgpuDeviceTick(device);
#else
    wgpuDevicePoll(device, 0, nullptr);
#endif
}

// ── Device features required by the plugin's threading model ──────────────
// Dawn devices are single-threaded unless ImplicitDeviceSynchronization is
// REQUESTED AS A FEATURE at device creation (it is not a toggle — a wrong
// name there is silently ignored). The plugin drives every device from the
// Dart thread, the callback pump, and the creation worker, so this is
// mandatory; wgpu-native's Rust core is thread-safe by construction.
inline void nwBackendAppendDeviceFeatures(WGPUAdapter adapter,
                                          std::vector<WGPUFeatureName>* out) {
#if defined(NITRO_WEBGPU_BACKEND_DAWN)
    out->push_back(WGPUFeatureName_ImplicitDeviceSynchronization);
    // Zero-copy presentation: import the compositor-shared texture
    // (IOSurface / DXGI shared handle) as a WGPUTexture and copy on-GPU.
    // Requested only when the adapter exposes it; the presenter probes the
    // device.
#if defined(__APPLE__)
    if (wgpuAdapterHasFeature(adapter,
                              WGPUFeatureName_SharedTextureMemoryIOSurface)) {
        out->push_back(WGPUFeatureName_SharedTextureMemoryIOSurface);
    }
    if (wgpuAdapterHasFeature(adapter,
                              WGPUFeatureName_SharedFenceMTLSharedEvent)) {
        out->push_back(WGPUFeatureName_SharedFenceMTLSharedEvent);
    }
#elif defined(_WIN32)
    if (wgpuAdapterHasFeature(
            adapter, WGPUFeatureName_SharedTextureMemoryDXGISharedHandle)) {
        out->push_back(WGPUFeatureName_SharedTextureMemoryDXGISharedHandle);
    }
    if (wgpuAdapterHasFeature(adapter,
                              WGPUFeatureName_SharedFenceDXGISharedHandle)) {
        out->push_back(WGPUFeatureName_SharedFenceDXGISharedHandle);
    }
#endif
#else
    (void)adapter;
    (void)out;
#endif
}

// ── Feature spellings ──────────────────────────────────────────────────────
// Timestamps on pass boundaries need an extra native feature whose enum
// value differs per implementation.
inline WGPUFeatureName nwBackendTimestampInsideEncodersFeature() {
#if defined(NITRO_WEBGPU_BACKEND_DAWN)
    return WGPUFeatureName_ChromiumExperimentalTimestampQueryInsidePasses;
#else
    return (WGPUFeatureName)WGPUNativeFeature_TimestampQueryInsideEncoders;
#endif
}

// ── Backend-bits mapping ───────────────────────────────────────────────────
// Maps the Dart-facing GpuBackend bitmask (1=Vulkan 2=Metal 4=DX12 8=GL) to
// what the instance descriptor consumes. wgpu-native: WGPUInstanceBackend
// flags. Dawn: no instance-level restriction — passthrough (unused).
inline uint64_t nwBackendMapBits(int64_t bits) {
#if defined(NITRO_WEBGPU_BACKEND_DAWN)
    return (uint64_t)bits;
#else
#if defined(__linux__) && !defined(__ANDROID__)
    // Flutter's GTK embedder owns the process's EGL context; wgpu-hal's GL
    // backend probe races it during adapter enumeration and panics
    // (egl.rs unwraps Err(BadAccess) → abort across the C ABI —
    // CI core-dump + stderr verified). Desktop Linux renders offscreen and
    // presents via CPU readback, so wgpu's GL backend is never needed:
    // default to Vulkan-only, and honor an explicit GL request only when
    // the caller opted in by name.
    if (bits == 0) return (uint64_t)WGPUInstanceBackend_Vulkan;
#else
    if (bits == 0) return (uint64_t)WGPUInstanceBackend_All;
#endif
    WGPUInstanceBackend out = 0;
    if (bits & (1 << 0)) out |= WGPUInstanceBackend_Vulkan;
    if (bits & (1 << 1)) out |= WGPUInstanceBackend_Metal;
    if (bits & (1 << 2)) out |= WGPUInstanceBackend_DX12;
    if (bits & (1 << 3)) out |= WGPUInstanceBackend_GL;
    return (uint64_t)out;
#endif
}

// ── Implementation version string ──────────────────────────────────────────
inline uint32_t nwBackendVersion() {
#if defined(NITRO_WEBGPU_BACKEND_DAWN)
    return 0;  // Dawn has no packed-version query; report 0.0.0.0
#else
    return wgpuGetVersion();
#endif
}

// ── Queue timestamp period ─────────────────────────────────────────────────
// Nanoseconds per timestamp tick. Dawn normalizes timestamps to
// nanoseconds (period 1.0); wgpu-native reports the raw device period.
inline float nwBackendQueueTimestampPeriod(WGPUQueue queue) {
#if defined(NITRO_WEBGPU_BACKEND_DAWN)
    (void)queue;
    return 1.0f;
#else
    return wgpuQueueGetTimestampPeriod(queue);
#endif
}

// ── GLSL ingestion ─────────────────────────────────────────────────────────
// wgpu-native: naga's glsl-in via WGPUShaderSourceGLSL. Dawn: glslang
// compiles the (Vulkan-dialect) GLSL to SPIR-V and Dawn ingests it via
// WGPUShaderSourceSPIRV (unlocked by the allow_unsafe_apis toggle).
inline bool nwBackendSupportsGlsl() {
#if defined(NITRO_WEBGPU_BACKEND_DAWN) && !defined(NITRO_WEBGPU_HAS_GLSLANG)
    return false;  // no glslang staged for this platform (yet)
#else
    return true;
#endif
}

#if defined(NITRO_WEBGPU_BACKEND_DAWN) && defined(NITRO_WEBGPU_HAS_GLSLANG)
inline WGPUShaderModule nwBackendCreateGlslModule(WGPUDevice device,
                                                  const char* source,
                                                  uint32_t stageBits,
                                                  const char* label,
                                                  std::string* outError) {
    static std::once_flag once;
    std::call_once(once, [] { glslang_initialize_process(); });
    const glslang_stage_t stage =
        stageBits == (uint32_t)WGPUShaderStage_Vertex    ? GLSLANG_STAGE_VERTEX
        : stageBits == (uint32_t)WGPUShaderStage_Compute ? GLSLANG_STAGE_COMPUTE
                                                         : GLSLANG_STAGE_FRAGMENT;
    glslang_input_t input = {};
    input.language = GLSLANG_SOURCE_GLSL;
    input.stage = stage;
    input.client = GLSLANG_CLIENT_VULKAN;
    input.client_version = GLSLANG_TARGET_VULKAN_1_1;
    input.target_language = GLSLANG_TARGET_SPV;
    input.target_language_version = GLSLANG_TARGET_SPV_1_3;
    input.code = source;
    input.default_version = 450;
    input.default_profile = GLSLANG_NO_PROFILE;
    input.messages = GLSLANG_MSG_DEFAULT_BIT;
    input.resource = glslang_default_resource();

    glslang_shader_t* shader = glslang_shader_create(&input);
    if (!glslang_shader_preprocess(shader, &input) ||
        !glslang_shader_parse(shader, &input)) {
        *outError = glslang_shader_get_info_log(shader);
        glslang_shader_delete(shader);
        return nullptr;
    }
    glslang_program_t* program = glslang_program_create();
    glslang_program_add_shader(program, shader);
    if (!glslang_program_link(program, GLSLANG_MSG_SPV_RULES_BIT |
                                           GLSLANG_MSG_VULKAN_RULES_BIT)) {
        *outError = glslang_program_get_info_log(program);
        glslang_program_delete(program);
        glslang_shader_delete(shader);
        return nullptr;
    }
    glslang_program_SPIRV_generate(program, stage);
    const size_t words = glslang_program_SPIRV_get_size(program);
    std::vector<uint32_t> spirv(words);
    glslang_program_SPIRV_get(program, spirv.data());
    glslang_program_delete(program);
    glslang_shader_delete(shader);

    WGPUShaderSourceSPIRV src = WGPU_SHADER_SOURCE_SPIRV_INIT;
    src.chain.sType = WGPUSType_ShaderSourceSPIRV;
    src.codeSize = (uint32_t)words;
    src.code = spirv.data();
    WGPUShaderModuleDescriptor desc = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
    desc.nextInChain = &src.chain;
    desc.label = {label, WGPU_STRLEN};
    return wgpuDeviceCreateShaderModule(device, &desc);
}
#endif
