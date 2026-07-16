// HybridNitroWebgpu — shared C++ implementation over wgpu-native.
// The webgpu.h ABI is provided by the vendored wgpu-native static library
// (scripts/fetch_wgpu_native.sh). Quoted includes resolve relative to this
// file, so no extra include paths are needed on any platform's build.
#include "../lib/src/generated/cpp/nitro_webgpu.native.g.h"

#include "native/dart_api_dl.h"
#include "third_party/wgpu_native/include/webgpu/webgpu.h"
#include "third_party/wgpu_native/include/webgpu/wgpu.h"

#ifdef __ANDROID__
#include <android/log.h>
#endif

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>

namespace {

// ── Native-async post helpers (vani pattern) ─────────────────────────────────

void postInt64(int64_t dartPort, int64_t value) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = value;
    Dart_PostCObject_DL(dartPort, &obj);
}

void postNull(int64_t dartPort) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kNull;
    Dart_PostCObject_DL(dartPort, &obj);
}

// Posts a record's malloc'd [4B len][payload] buffer as a pointer; Dart
// decodes it and frees it via the nitro_webgpu_nitro_free export.
void postRecord(int64_t dartPort, NitroCppBuffer buffer) {
    if (!buffer.data) {
        postNull(dartPort);
        return;
    }
    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (int64_t)(intptr_t)buffer.data;
    Dart_PostCObject_DL(dartPort, &obj);
}

void fillError(NitroError* err, const char* name, const std::string& message) {
    if (!err) return;
    err->hasError = 1;
    err->name = strdup(name);
    err->message = strdup(message.c_str());
    err->code = nullptr;
    err->stackTrace = nullptr;
}

std::string toStd(WGPUStringView v) {
    if (!v.data) return {};
    if (v.length == WGPU_STRLEN) return std::string(v.data);
    return std::string(v.data, v.length);
}

WGPUStringView toView(const std::string& s) {
    return WGPUStringView{s.data(), s.length()};
}

void fillLimits(const WGPULimits& limits, GpuLimits& out) {
    out.maxTextureDimension1D = limits.maxTextureDimension1D;
    out.maxTextureDimension2D = limits.maxTextureDimension2D;
    out.maxTextureDimension3D = limits.maxTextureDimension3D;
    out.maxTextureArrayLayers = limits.maxTextureArrayLayers;
    out.maxBindGroups = limits.maxBindGroups;
    out.maxBindGroupsPlusVertexBuffers = limits.maxBindGroupsPlusVertexBuffers;
    out.maxBindingsPerBindGroup = limits.maxBindingsPerBindGroup;
    out.maxDynamicUniformBuffersPerPipelineLayout =
        limits.maxDynamicUniformBuffersPerPipelineLayout;
    out.maxDynamicStorageBuffersPerPipelineLayout =
        limits.maxDynamicStorageBuffersPerPipelineLayout;
    out.maxSampledTexturesPerShaderStage =
        limits.maxSampledTexturesPerShaderStage;
    out.maxSamplersPerShaderStage = limits.maxSamplersPerShaderStage;
    out.maxStorageBuffersPerShaderStage =
        limits.maxStorageBuffersPerShaderStage;
    out.maxStorageTexturesPerShaderStage =
        limits.maxStorageTexturesPerShaderStage;
    out.maxUniformBuffersPerShaderStage =
        limits.maxUniformBuffersPerShaderStage;
    out.maxUniformBufferBindingSize =
        (int64_t)limits.maxUniformBufferBindingSize;
    out.maxStorageBufferBindingSize =
        (int64_t)limits.maxStorageBufferBindingSize;
    out.minUniformBufferOffsetAlignment =
        limits.minUniformBufferOffsetAlignment;
    out.minStorageBufferOffsetAlignment =
        limits.minStorageBufferOffsetAlignment;
    out.maxVertexBuffers = limits.maxVertexBuffers;
    out.maxBufferSize = (int64_t)limits.maxBufferSize;
    out.maxVertexAttributes = limits.maxVertexAttributes;
    out.maxVertexBufferArrayStride = limits.maxVertexBufferArrayStride;
    out.maxInterStageShaderVariables = limits.maxInterStageShaderVariables;
    out.maxColorAttachments = limits.maxColorAttachments;
    out.maxColorAttachmentBytesPerSample =
        limits.maxColorAttachmentBytesPerSample;
    out.maxComputeWorkgroupStorageSize =
        limits.maxComputeWorkgroupStorageSize;
    out.maxComputeInvocationsPerWorkgroup =
        limits.maxComputeInvocationsPerWorkgroup;
    out.maxComputeWorkgroupSizeX = limits.maxComputeWorkgroupSizeX;
    out.maxComputeWorkgroupSizeY = limits.maxComputeWorkgroupSizeY;
    out.maxComputeWorkgroupSizeZ = limits.maxComputeWorkgroupSizeZ;
    out.maxComputeWorkgroupsPerDimension =
        limits.maxComputeWorkgroupsPerDimension;
}

// Requested overrides (-1 = keep default) applied onto a WGPU_LIMITS_INIT.
void applyRequiredLimits(const GpuRequiredLimits& rl, WGPULimits& limits) {
#define NWG_L32(name)     if (rl.name >= 0) limits.name = (uint32_t)rl.name
#define NWG_L64(name)     if (rl.name >= 0) limits.name = (uint64_t)rl.name
    NWG_L32(maxTextureDimension1D);
    NWG_L32(maxTextureDimension2D);
    NWG_L32(maxTextureDimension3D);
    NWG_L32(maxTextureArrayLayers);
    NWG_L32(maxBindGroups);
    NWG_L32(maxBindGroupsPlusVertexBuffers);
    NWG_L32(maxBindingsPerBindGroup);
    NWG_L32(maxDynamicUniformBuffersPerPipelineLayout);
    NWG_L32(maxDynamicStorageBuffersPerPipelineLayout);
    NWG_L32(maxSampledTexturesPerShaderStage);
    NWG_L32(maxSamplersPerShaderStage);
    NWG_L32(maxStorageBuffersPerShaderStage);
    NWG_L32(maxStorageTexturesPerShaderStage);
    NWG_L32(maxUniformBuffersPerShaderStage);
    NWG_L64(maxUniformBufferBindingSize);
    NWG_L64(maxStorageBufferBindingSize);
    NWG_L32(minUniformBufferOffsetAlignment);
    NWG_L32(minStorageBufferOffsetAlignment);
    NWG_L32(maxVertexBuffers);
    NWG_L64(maxBufferSize);
    NWG_L32(maxVertexAttributes);
    NWG_L32(maxVertexBufferArrayStride);
    NWG_L32(maxInterStageShaderVariables);
    NWG_L32(maxColorAttachments);
    NWG_L32(maxColorAttachmentBytesPerSample);
    NWG_L32(maxComputeWorkgroupStorageSize);
    NWG_L32(maxComputeInvocationsPerWorkgroup);
    NWG_L32(maxComputeWorkgroupSizeX);
    NWG_L32(maxComputeWorkgroupSizeY);
    NWG_L32(maxComputeWorkgroupSizeZ);
    NWG_L32(maxComputeWorkgroupsPerDimension);
#undef NWG_L32
#undef NWG_L64
}

// Standard features (value < 63) packed as a bitmask: bit i = feature i.
int64_t packFeatureBits(const WGPUSupportedFeatures& f) {
    int64_t bits = 0;
    for (size_t i = 0; i < f.featureCount; i++) {
        const uint32_t v = (uint32_t)f.features[i];
        if (v < 63) bits |= (int64_t)1 << v;
    }
    return bits;
}

// ── Curated GpuBackend bits → WGPUInstanceBackend ────────────────────────────
// (see GpuBackend in nitro_webgpu.native.dart — the Dart API never carries raw
// wgpu ABI values)

WGPUInstanceBackend mapBackends(int64_t bits) {
    if (bits == 0) return WGPUInstanceBackend_All;
    WGPUInstanceBackend out = 0;
    if (bits & (1 << 0)) out |= WGPUInstanceBackend_Vulkan;
    if (bits & (1 << 1)) out |= WGPUInstanceBackend_Metal;
    if (bits & (1 << 2)) out |= WGPUInstanceBackend_DX12;
    if (bits & (1 << 3)) out |= WGPUInstanceBackend_GL;
    return out;
}

// ── WgpuContext ──────────────────────────────────────────────────────────────
// Owns the process-wide WGPUInstance and the callback pump thread.
//
// Threading contract:
//  - The Dart mutator thread makes all synchronous wgpu calls (wgpu-native is
//    internally synchronized, so this may overlap the pump safely).
//  - AllowProcessEvents callbacks fire on the pump thread inside
//    wgpuInstanceProcessEvents / wgpuDevicePoll.
//  - Callbacks only marshal results and call Dart_PostCObject_DL / emit_*
//    (both thread-safe); they never re-enter the wgpu API.

class WgpuContext {
public:
    static WgpuContext& get() {
        static WgpuContext* ctx = new WgpuContext();  // never destroyed
        return *ctx;
    }

    void init(int64_t backendBits) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (instance_) return;  // idempotent
        // Route wgpu's own logs to the platform log so adapter selection and
        // driver issues are diagnosable in the field.
        wgpuSetLogLevel(WGPULogLevel_Warn);
        wgpuSetLogCallback(
            [](WGPULogLevel level, WGPUStringView message, void*) {
#ifdef __ANDROID__
                __android_log_print(
                    level <= WGPULogLevel_Error ? ANDROID_LOG_ERROR
                                                : ANDROID_LOG_WARN,
                    "wgpu", "%.*s", (int)message.length, message.data);
#else
                fprintf(stderr, "[wgpu:%d] %.*s\n", (int)level,
                        (int)message.length, message.data);
#endif
            },
            nullptr);
        WGPUInstanceExtras extras = {};
        extras.chain.sType = static_cast<WGPUSType>(WGPUSType_InstanceExtras);
        extras.backends = mapBackends(backendBits);
        WGPUInstanceDescriptor desc = {};
        desc.nextInChain = &extras.chain;
        instance_ = wgpuCreateInstance(&desc);
        if (!instance_) {
            throw std::runtime_error("wgpuCreateInstance failed");
        }
        pump_ = std::thread([this] { pumpLoop(); });
        pump_.detach();  // process-lifetime singleton
    }

    WGPUInstance instance() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!instance_) {
            throw std::runtime_error(
                "WebGPU instance not initialized — call initInstance() first");
        }
        return instance_;
    }

    // Async-op accounting: while ops are pending the pump spins fast so
    // AllowProcessEvents callbacks complete promptly.
    void opStarted() {
        pendingOps_.fetch_add(1, std::memory_order_acq_rel);
        cv_.notify_one();
    }
    void opFinished() { pendingOps_.fetch_sub(1, std::memory_order_acq_rel); }

    // The poll registry is refcounted: the Dart-owned device handle holds one
    // registration, and each presenter holds another — so in-flight presenter
    // readbacks keep completing even after the app released its device handle.
    void registerDevice(WGPUDevice device) {
        std::lock_guard<std::mutex> lock(devicesMutex_);
        ++devices_[device];
        cv_.notify_one();
    }

    void unregisterDevice(WGPUDevice device) {
        std::lock_guard<std::mutex> lock(devicesMutex_);
        auto it = devices_.find(device);
        if (it != devices_.end() && --it->second == 0) devices_.erase(it);
    }

    // Drops the Dart handle's registration and releases it under the same
    // lock, so the pump can never poll a fully-released handle.
    void unregisterAndRelease(WGPUDevice device) {
        {
            std::lock_guard<std::mutex> lock(devicesMutex_);
            auto it = devices_.find(device);
            if (it != devices_.end() && --it->second == 0) devices_.erase(it);
            wgpuDeviceRelease(device);
        }
        // The device-lost event is delivered through the instance event queue;
        // keep pumping briefly so it reaches Dart even though the device may
        // be gone from the poll sweep.
        pokePump(500);
    }

    // Keeps the pump ticking for [ms] more milliseconds even with no devices
    // and no pending ops.
    void pokePump(int64_t ms) {
        lingerUntilMs_.store(nowMs() + ms, std::memory_order_release);
        cv_.notify_one();
    }

private:
    void pumpLoop() {
        for (;;) {
            {
                std::unique_lock<std::mutex> lock(cvMutex_);
                if (pendingOps_.load(std::memory_order_acquire) == 0) {
                    if (hasDevices() || nowMs() < lingerUntilMs_.load(std::memory_order_acquire)) {
                        // Idle but devices alive (or lingering after a device
                        // release): tick to deliver spontaneous events
                        // (device lost, uncaptured errors).
                        cv_.wait_for(lock, std::chrono::milliseconds(100));
                    } else {
                        cv_.wait(lock, [this] {
                            return pendingOps_.load(std::memory_order_acquire) > 0 ||
                                   hasDevices() ||
                                   nowMs() < lingerUntilMs_.load(std::memory_order_acquire);
                        });
                    }
                }
            }
            wgpuInstanceProcessEvents(instance_);
            {
                std::lock_guard<std::mutex> lock(devicesMutex_);
                for (const auto& [device, refs] : devices_) {
                    wgpuDevicePoll(device, /*wait=*/0, nullptr);
                }
            }
            if (pendingOps_.load(std::memory_order_acquire) > 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
    }

    bool hasDevices() {
        std::lock_guard<std::mutex> lock(devicesMutex_);
        return !devices_.empty();
    }

    static int64_t nowMs() {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
                   std::chrono::steady_clock::now().time_since_epoch())
            .count();
    }

    std::mutex mutex_;
    std::mutex cvMutex_;
    std::mutex devicesMutex_;
    std::condition_variable cv_;
    std::atomic<int> pendingOps_{0};
    std::atomic<int64_t> lingerUntilMs_{0};
    std::unordered_map<WGPUDevice, int> devices_;
    WGPUInstance instance_ = nullptr;
    std::thread pump_;
};

// Some Android vendors ship SwiftShader as a system Vulkan ICD and wgpu's
// requestAdapter can hand it back even at HighPerformance. Before falling
// back to wgpuInstanceRequestAdapter, enumerate every adapter and pick real
// hardware directly. Runs on the Dart thread (never inside a wgpu callback —
// re-entering wgpu from a callback panics).
WGPUAdapter pickHardwareAdapter(int64_t powerPreference) {
    WGPUInstance instance = WgpuContext::get().instance();
    size_t count = wgpuInstanceEnumerateAdapters(instance, nullptr, nullptr);
    if (count == 0) return nullptr;
    std::vector<WGPUAdapter> adapters(count);
    count = wgpuInstanceEnumerateAdapters(instance, nullptr, adapters.data());

    // powerPreference: 1 = low power (prefer integrated), else prefer discrete.
    const bool lowPower = powerPreference == 1;
    auto rank = [lowPower](WGPUAdapterType t) {
        switch (t) {
            case WGPUAdapterType_DiscreteGPU: return lowPower ? 1 : 0;
            case WGPUAdapterType_IntegratedGPU: return lowPower ? 0 : 1;
            case WGPUAdapterType_Unknown: return 2;
            default: return 3;  // CPU — never picked here
        }
    };
    WGPUAdapter best = nullptr;
    int bestRank = 3;
    for (size_t i = 0; i < count; i++) {
        if (!adapters[i]) continue;
        WGPUAdapterInfo ai = WGPU_ADAPTER_INFO_INIT;
        if (wgpuAdapterGetInfo(adapters[i], &ai) != WGPUStatus_Success) continue;
        const int r = rank(ai.adapterType);
        wgpuAdapterInfoFreeMembers(ai);
        if (r < bestRank) {
            bestRank = r;
            best = adapters[i];
        }
    }
    for (auto a : adapters) {
        if (a && a != best) wgpuAdapterRelease(a);
    }
    if (bestRank >= 3) {
        if (best) wgpuAdapterRelease(best);
        return nullptr;  // only CPU adapters exist — use the normal path
    }
    return best;
}

// Pending async op: the NitroError slot stays alive until Dart receives the
// port message, so callbacks may safely fill it before posting.
struct PendingOp {
    NitroError* err;
    int64_t port;
};

class HybridNitroWebgpuImpl;
HybridNitroWebgpuImpl* gImpl = nullptr;

class HybridNitroWebgpuImpl final : public HybridNitroWebgpu {
public:
    // ── Instance ─────────────────────────────────────────────────────────

    void initInstance(NitroCppBuffer options) override {
        const auto opts = GpuInstanceOptions::fromNative(options);
        WgpuContext::get().init(opts.backends);
    }

    std::string wgpuVersion() override {
        const uint32_t v = wgpuGetVersion();
        char out[24];
        std::snprintf(out, sizeof(out), "%u.%u.%u.%u",
                      (v >> 24) & 0xFFu, (v >> 16) & 0xFFu, (v >> 8) & 0xFFu, v & 0xFFu);
        return out;
    }

    // ── Adapter ──────────────────────────────────────────────────────────

    void requestAdapter(NitroCppBuffer options, NitroError* _nitro_err,
                        int64_t dartPort) override {
        const auto opts = GpuRequestAdapterOptions::fromNative(options);
        WGPURequestAdapterOptions wgpuOpts = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
        wgpuOpts.powerPreference = static_cast<WGPUPowerPreference>(opts.powerPreference);
        wgpuOpts.forceFallbackAdapter = opts.forceFallbackAdapter ? 1 : 0;

        // Fast path: pick real hardware from enumeration (guards against
        // vendor SwiftShader ICDs winning the default selection).
        if (!opts.forceFallbackAdapter) {
            if (WGPUAdapter hw = pickHardwareAdapter(opts.powerPreference)) {
                postInt64(dartPort, (int64_t)(intptr_t)hw);
                return;
            }
        }

        auto* op = new PendingOp{_nitro_err, dartPort};
        WGPURequestAdapterCallbackInfo cb = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
        cb.mode = WGPUCallbackMode_AllowProcessEvents;
        cb.userdata1 = op;
        cb.callback = [](WGPURequestAdapterStatus status, WGPUAdapter adapter,
                         WGPUStringView message, void* ud1, void*) {
            auto* op = static_cast<PendingOp*>(ud1);
            if (status == WGPURequestAdapterStatus_Success && adapter) {
                postInt64(op->port, (int64_t)(intptr_t)adapter);
            } else {
                fillError(op->err, "GpuAdapterError",
                          message.data ? toStd(message) : "No suitable GPU adapter found");
                postNull(op->port);
            }
            WgpuContext::get().opFinished();
            delete op;
        };
        wgpuInstanceRequestAdapter(WgpuContext::get().instance(), &wgpuOpts, cb);
        WgpuContext::get().opStarted();
    }

    NitroCppBuffer adapterGetInfo(int64_t adapter) override {
        WGPUAdapterInfo info = WGPU_ADAPTER_INFO_INIT;
        if (wgpuAdapterGetInfo((WGPUAdapter)(intptr_t)adapter, &info) != WGPUStatus_Success) {
            throw std::runtime_error("wgpuAdapterGetInfo failed");
        }
        GpuAdapterInfo out;
        out.vendor = toStd(info.vendor);
        out.architecture = toStd(info.architecture);
        out.device = toStd(info.device);
        out.description = toStd(info.description);
        out.backendType = (int64_t)info.backendType;
        out.adapterType = (int64_t)info.adapterType;
        wgpuAdapterInfoFreeMembers(info);
        return out.toNativeBuffer();
    }

    NitroCppBuffer adapterGetLimits(int64_t adapter) override {
        WGPULimits limits = WGPU_LIMITS_INIT;
        if (wgpuAdapterGetLimits((WGPUAdapter)(intptr_t)adapter, &limits) != WGPUStatus_Success) {
            throw std::runtime_error("wgpuAdapterGetLimits failed");
        }
        GpuLimits out;
        fillLimits(limits, out);
        return out.toNativeBuffer();
    }

    int64_t adapterGetFeatures(int64_t adapter) override {
        WGPUSupportedFeatures f = {};
        wgpuAdapterGetFeatures((WGPUAdapter)(intptr_t)adapter, &f);
        const int64_t bits = packFeatureBits(f);
        wgpuSupportedFeaturesFreeMembers(f);
        return bits;
    }

    bool adapterHasTimestampQuery(int64_t adapter) override {
        return wgpuAdapterHasFeature((WGPUAdapter)(intptr_t)adapter,
                                     WGPUFeatureName_TimestampQuery) != 0;
    }

    void adapterRelease(int64_t adapter) override {
        wgpuAdapterRelease((WGPUAdapter)(intptr_t)adapter);
    }

    // ── Device / queue ───────────────────────────────────────────────────

    void requestDevice(int64_t adapter, NitroCppBuffer descriptor,
                       NitroError* _nitro_err, int64_t dartPort) override {
        const auto desc = GpuDeviceDescriptor::fromNative(descriptor);

        // Kept alive for the duration of the request; wgpu copies the label.
        auto* label = new std::string(desc.label);

        WGPUDeviceDescriptor wgpuDesc = WGPU_DEVICE_DESCRIPTOR_INIT;
        wgpuDesc.label = toView(*label);

        // Kept alive until the request callback runs (like the label).
        auto* features = new std::vector<WGPUFeatureName>();
        const bool wantsTimestamps =
            desc.requireTimestampQueries ||
            ((desc.requiredFeatures >> WGPUFeatureName_TimestampQuery) & 1);
        if (desc.requireTimestampQueries) {
            features->push_back(WGPUFeatureName_TimestampQuery);
        }
        // wgpu-native gates encoder-level writeTimestamp behind an extras
        // feature; enable it with timestamps whenever the adapter has it.
        const auto kTsInsideEncoders =
            (WGPUFeatureName)WGPUNativeFeature_TimestampQueryInsideEncoders;
        if (wantsTimestamps &&
            wgpuAdapterHasFeature((WGPUAdapter)(intptr_t)adapter,
                                  kTsInsideEncoders)) {
            features->push_back(kTsInsideEncoders);
        }
        for (int i = 1; i < 63; i++) {
            if (((desc.requiredFeatures >> i) & 1) == 0) continue;
            if (i == (int)WGPUFeatureName_TimestampQuery &&
                desc.requireTimestampQueries) {
                continue;
            }
            features->push_back((WGPUFeatureName)i);
        }
        if (!features->empty()) {
            wgpuDesc.requiredFeatureCount = features->size();
            wgpuDesc.requiredFeatures = features->data();
        }

        WGPULimits limits = WGPU_LIMITS_INIT;
        if (desc.requiredLimits.has_value()) {
            applyRequiredLimits(*desc.requiredLimits, limits);
            wgpuDesc.requiredLimits = &limits;
        }

        wgpuDesc.deviceLostCallbackInfo.mode = WGPUCallbackMode_AllowSpontaneous;
        wgpuDesc.deviceLostCallbackInfo.callback =
            [](WGPUDevice const* device, WGPUDeviceLostReason reason,
               WGPUStringView message, void*, void*) {
                if (!gImpl) return;
                GpuDeviceLost ev;
                ev.deviceAddress = device ? (int64_t)(intptr_t)*device : 0;
                ev.reason = (int64_t)reason;
                ev.message = toStd(message);
                gImpl->emit_deviceLostEvents(ev.toNativeBuffer());
            };

        wgpuDesc.uncapturedErrorCallbackInfo.callback =
            [](WGPUDevice const* device, WGPUErrorType type,
               WGPUStringView message, void*, void*) {
                if (!gImpl) return;
                GpuUncapturedError ev;
                ev.deviceAddress = device ? (int64_t)(intptr_t)*device : 0;
                ev.type = (int64_t)type;
                ev.message = toStd(message);
                gImpl->emit_uncapturedErrors(ev.toNativeBuffer());
            };

        struct DeviceOp {
            PendingOp op;
            std::string* label;
            std::vector<WGPUFeatureName>* features;
        };
        auto* dop = new DeviceOp{{_nitro_err, dartPort}, label, features};

        WGPURequestDeviceCallbackInfo cb = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
        cb.mode = WGPUCallbackMode_AllowProcessEvents;
        cb.userdata1 = dop;
        cb.callback = [](WGPURequestDeviceStatus status, WGPUDevice device,
                         WGPUStringView message, void* ud1, void*) {
            auto* dop = static_cast<DeviceOp*>(ud1);
            if (status == WGPURequestDeviceStatus_Success && device) {
                WgpuContext::get().registerDevice(device);
                postInt64(dop->op.port, (int64_t)(intptr_t)device);
            } else {
                fillError(dop->op.err, "GpuDeviceError",
                          message.data ? toStd(message) : "requestDevice failed");
                postNull(dop->op.port);
            }
            WgpuContext::get().opFinished();
            delete dop->label;
            delete dop->features;
            delete dop;
        };
        wgpuAdapterRequestDevice((WGPUAdapter)(intptr_t)adapter, &wgpuDesc, cb);
        WgpuContext::get().opStarted();
    }

    int64_t deviceGetQueue(int64_t device) override {
        WGPUQueue queue = wgpuDeviceGetQueue((WGPUDevice)(intptr_t)device);
        if (!queue) throw std::runtime_error("wgpuDeviceGetQueue failed");
        return (int64_t)(intptr_t)queue;
    }

    void deviceDestroy(int64_t device) override {
        wgpuDeviceDestroy((WGPUDevice)(intptr_t)device);
        // The lost event is delivered through the event queue; make sure the
        // pump ticks even if this device was the only pending work.
        WgpuContext::get().pokePump(500);
    }

    void deviceRelease(int64_t device) override {
        {
            std::lock_guard<std::mutex> lock(scopesMutex_);
            errorScopeDepth_.erase(device);
        }
        WgpuContext::get().unregisterAndRelease((WGPUDevice)(intptr_t)device);
    }

    void queueRelease(int64_t queue) override {
        wgpuQueueRelease((WGPUQueue)(intptr_t)queue);
    }

    int64_t deviceGetFeatures(int64_t device) override {
        WGPUSupportedFeatures f = {};
        wgpuDeviceGetFeatures((WGPUDevice)(intptr_t)device, &f);
        const int64_t bits = packFeatureBits(f);
        wgpuSupportedFeaturesFreeMembers(f);
        return bits;
    }

    // ── Error handling ───────────────────────────────────────────────────

    void devicePushErrorScope(int64_t device, int64_t filter) override {
        {
            std::lock_guard<std::mutex> lock(scopesMutex_);
            ++errorScopeDepth_[device];
        }
        wgpuDevicePushErrorScope((WGPUDevice)(intptr_t)device,
                                 static_cast<WGPUErrorFilter>(filter));
    }

    void devicePopErrorScope(int64_t device, NitroError* _nitro_err,
                             int64_t dartPort) override {
        // wgpu-native panics (aborts the process) on an unbalanced pop, so the
        // scope depth is tracked here and misuse is rejected as a Dart error.
        {
            std::lock_guard<std::mutex> lock(scopesMutex_);
            auto it = errorScopeDepth_.find(device);
            if (it == errorScopeDepth_.end() || it->second == 0) {
                fillError(_nitro_err, "GpuErrorScopeError",
                          "popErrorScope called with no active error scope");
                postNull(dartPort);
                return;
            }
            --it->second;
        }
        auto* op = new PendingOp{_nitro_err, dartPort};
        WGPUPopErrorScopeCallbackInfo cb = WGPU_POP_ERROR_SCOPE_CALLBACK_INFO_INIT;
        cb.mode = WGPUCallbackMode_AllowProcessEvents;
        cb.userdata1 = op;
        cb.callback = [](WGPUPopErrorScopeStatus status, WGPUErrorType type,
                         WGPUStringView message, void* ud1, void*) {
            auto* op = static_cast<PendingOp*>(ud1);
            if (status != WGPUPopErrorScopeStatus_Success) {
                fillError(op->err, "GpuErrorScopeError",
                          message.data ? toStd(message)
                                       : "popErrorScope failed (empty scope stack?)");
                postNull(op->port);
            } else if (type == WGPUErrorType_NoError) {
                // Nullable-record convention: address 0 decodes to Dart null.
                postInt64(op->port, 0);
            } else {
                GpuError err;
                err.type = (int64_t)type;
                err.message = toStd(message);
                postRecord(op->port, err.toNativeBuffer());
            }
            WgpuContext::get().opFinished();
            delete op;
        };
        wgpuDevicePopErrorScope((WGPUDevice)(intptr_t)device, cb);
        WgpuContext::get().opStarted();
    }

    // ── Buffers ──────────────────────────────────────────────────────────

    int64_t deviceCreateBuffer(int64_t device, NitroCppBuffer descriptor) override {
        const auto d = GpuBufferDescriptor::fromNative(descriptor);
        WGPUBufferDescriptor wd = WGPU_BUFFER_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        wd.usage = (WGPUBufferUsage)d.usage;
        wd.size = (uint64_t)d.size;
        wd.mappedAtCreation = d.mappedAtCreation ? 1 : 0;
        WGPUBuffer buf = wgpuDeviceCreateBuffer((WGPUDevice)(intptr_t)device, &wd);
        if (!buf) throw std::runtime_error("wgpuDeviceCreateBuffer failed");
        return (int64_t)(intptr_t)buf;
    }

    void bufferDestroy(int64_t buffer) override {
        wgpuBufferDestroy((WGPUBuffer)(intptr_t)buffer);
    }

    void bufferRelease(int64_t buffer) override {
        wgpuBufferRelease((WGPUBuffer)(intptr_t)buffer);
    }

    int64_t bufferGetSize(int64_t buffer) override {
        return (int64_t)wgpuBufferGetSize((WGPUBuffer)(intptr_t)buffer);
    }

    void queueWriteBuffer(int64_t queue, int64_t buffer, int64_t bufferOffset,
                          const uint8_t* data, size_t data_length) override {
        wgpuQueueWriteBuffer((WGPUQueue)(intptr_t)queue,
                             (WGPUBuffer)(intptr_t)buffer,
                             (uint64_t)bufferOffset, data, data_length);
    }

    void bufferMapRead(int64_t buffer, int64_t offset, int64_t size,
                       NitroError* _nitro_err, int64_t dartPort) override {
        struct MapOp {
            NitroError* err;
            int64_t port;
            WGPUBuffer buf;
            size_t offset;
            size_t size;
        };
        auto* op = new MapOp{_nitro_err, dartPort, (WGPUBuffer)(intptr_t)buffer,
                             (size_t)offset, (size_t)size};
        WGPUBufferMapCallbackInfo cb = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
        cb.mode = WGPUCallbackMode_AllowProcessEvents;
        cb.userdata1 = op;
        cb.callback = [](WGPUMapAsyncStatus status, WGPUStringView message,
                         void* ud1, void*) {
            // Runs on the pump thread. getMappedRange/unmap inside a map
            // callback is safe — validated by the standalone compute probe.
            auto* op = static_cast<MapOp*>(ud1);
            if (status == WGPUMapAsyncStatus_Success) {
                const void* p =
                    wgpuBufferGetConstMappedRange(op->buf, op->offset, op->size);
                if (p) {
                    GpuMappedData md;
                    md.data.assign((const uint8_t*)p, (const uint8_t*)p + op->size);
                    wgpuBufferUnmap(op->buf);
                    postRecord(op->port, md.toNativeBuffer());
                } else {
                    wgpuBufferUnmap(op->buf);
                    fillError(op->err, "GpuMapError",
                              "getMappedRange returned null");
                    postNull(op->port);
                }
            } else {
                fillError(op->err, "GpuMapError",
                          message.data ? toStd(message) : "mapAsync failed");
                postNull(op->port);
            }
            WgpuContext::get().opFinished();
            delete op;
        };
        wgpuBufferMapAsync(op->buf, WGPUMapMode_Read, op->offset, op->size, cb);
        WgpuContext::get().opStarted();
    }

    void bufferMapWrite(int64_t buffer, int64_t offset, int64_t size,
                        NitroError* _nitro_err, int64_t dartPort) override {
        auto* op = new PendingOp{_nitro_err, dartPort};
        WGPUBufferMapCallbackInfo cb = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
        cb.mode = WGPUCallbackMode_AllowProcessEvents;
        cb.userdata1 = op;
        cb.callback = [](WGPUMapAsyncStatus status, WGPUStringView message,
                         void* ud1, void*) {
            auto* op = static_cast<PendingOp*>(ud1);
            if (status != WGPUMapAsyncStatus_Success) {
                fillError(op->err, "GpuMapError",
                          message.data ? toStd(message)
                                       : "mapAsync(write) failed");
            }
            postNull(op->port);
            WgpuContext::get().opFinished();
            delete op;
        };
        wgpuBufferMapAsync((WGPUBuffer)(intptr_t)buffer, WGPUMapMode_Write,
                           (size_t)offset, (size_t)size, cb);
        WgpuContext::get().opStarted();
    }

    void bufferWriteMapped(int64_t buffer, int64_t offset, const uint8_t* data,
                           size_t data_length) override {
        // Zero-copy upload: the Dart buffer is written straight into the
        // mapped GPU allocation. wgpu-native v29.0.1.1 ships
        // wgpuBufferWriteMappedRange / wgpuBufferGetMappedRange as todo!()
        // panics (probe-verified), so this goes through the const getter —
        // it returns the same host-visible mapping, and the write+unmap
        // round-trip is probe-verified against the static lib.
        const void* p = wgpuBufferGetConstMappedRange(
            (WGPUBuffer)(intptr_t)buffer, (size_t)offset, data_length);
        if (!p) {
            throw std::runtime_error(
                "bufferWriteMapped failed — is the buffer mapped and the "
                "range in bounds?");
        }
        std::memcpy(const_cast<void*>(p), data, data_length);
    }

    void bufferUnmap(int64_t buffer) override {
        wgpuBufferUnmap((WGPUBuffer)(intptr_t)buffer);
    }

    int64_t bufferGetUsage(int64_t buffer) override {
        return (int64_t)wgpuBufferGetUsage((WGPUBuffer)(intptr_t)buffer);
    }

    // ── Shaders / pipelines / bind groups ────────────────────────────────

    int64_t deviceCreateShaderModuleWgsl(int64_t device, const std::string& label,
                                         const std::string& wgsl) override {
        WGPUShaderSourceWGSL src = WGPU_SHADER_SOURCE_WGSL_INIT;
        src.chain.sType = WGPUSType_ShaderSourceWGSL;
        src.code = toView(wgsl);
        WGPUShaderModuleDescriptor desc = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
        desc.nextInChain = &src.chain;
        desc.label = toView(label);
        WGPUShaderModule mod =
            wgpuDeviceCreateShaderModule((WGPUDevice)(intptr_t)device, &desc);
        if (!mod) throw std::runtime_error("wgpuDeviceCreateShaderModule failed");
        return (int64_t)(intptr_t)mod;
    }

    void shaderModuleRelease(int64_t module) override {
        wgpuShaderModuleRelease((WGPUShaderModule)(intptr_t)module);
    }

    void shaderModuleGetCompilationInfo(int64_t module, NitroError* _nitro_err,
                                        int64_t dartPort) override {
        // wgpu-native v29.0.1.1 ships wgpuShaderModuleGetCompilationInfo as a
        // todo!() Rust panic (probe-verified — it aborts the process), so it
        // must not be called. Compile errors already surface with naga's full
        // message through the checked-create error scope; resolve with an
        // empty diagnostics list until upstream implements the query.
        (void)module;
        (void)_nitro_err;
        GpuCompilationInfo out;
        postRecord(dartPort, out.toNativeBuffer());
    }

    int64_t deviceCreateComputePipeline(int64_t device,
                                        NitroCppBuffer descriptor) override {
        const auto d = GpuComputePipelineDescriptor::fromNative(descriptor);
        WGPUComputePipelineDescriptor wd = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        wd.layout = d.layoutAddress
                        ? (WGPUPipelineLayout)(intptr_t)d.layoutAddress
                        : nullptr;
        wd.compute.module = (WGPUShaderModule)(intptr_t)d.moduleAddress;
        wd.compute.entryPoint = toView(d.entryPoint);
        WGPUComputePipeline p =
            wgpuDeviceCreateComputePipeline((WGPUDevice)(intptr_t)device, &wd);
        if (!p) throw std::runtime_error("wgpuDeviceCreateComputePipeline failed");
        return (int64_t)(intptr_t)p;
    }

    void computePipelineRelease(int64_t pipeline) override {
        wgpuComputePipelineRelease((WGPUComputePipeline)(intptr_t)pipeline);
    }

    int64_t computePipelineGetBindGroupLayout(int64_t pipeline,
                                              int64_t groupIndex) override {
        WGPUBindGroupLayout layout = wgpuComputePipelineGetBindGroupLayout(
            (WGPUComputePipeline)(intptr_t)pipeline, (uint32_t)groupIndex);
        if (!layout) {
            throw std::runtime_error("computePipelineGetBindGroupLayout failed");
        }
        return (int64_t)(intptr_t)layout;
    }

    void bindGroupLayoutRelease(int64_t layout) override {
        wgpuBindGroupLayoutRelease((WGPUBindGroupLayout)(intptr_t)layout);
    }

    int64_t deviceCreateBindGroup(int64_t device,
                                  NitroCppBuffer descriptor) override {
        const auto d = GpuBindGroupDescriptor::fromNative(descriptor);
        std::vector<WGPUBindGroupEntry> entries(d.entries.size());
        for (size_t i = 0; i < d.entries.size(); i++) {
            const auto& e = d.entries[i];
            entries[i] = WGPU_BIND_GROUP_ENTRY_INIT;
            entries[i].binding = (uint32_t)e.binding;
            if (e.bufferAddress) {
                entries[i].buffer = (WGPUBuffer)(intptr_t)e.bufferAddress;
                entries[i].offset = (uint64_t)e.offset;
                entries[i].size =
                    e.size < 0 ? WGPU_WHOLE_SIZE : (uint64_t)e.size;
            } else if (e.samplerAddress) {
                entries[i].sampler = (WGPUSampler)(intptr_t)e.samplerAddress;
            } else if (e.textureViewAddress) {
                entries[i].textureView =
                    (WGPUTextureView)(intptr_t)e.textureViewAddress;
            }
        }
        WGPUBindGroupDescriptor wd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        wd.layout = (WGPUBindGroupLayout)(intptr_t)d.layoutAddress;
        wd.entryCount = entries.size();
        wd.entries = entries.data();
        WGPUBindGroup bg =
            wgpuDeviceCreateBindGroup((WGPUDevice)(intptr_t)device, &wd);
        if (!bg) throw std::runtime_error("wgpuDeviceCreateBindGroup failed");
        return (int64_t)(intptr_t)bg;
    }

    void bindGroupRelease(int64_t bindGroup) override {
        wgpuBindGroupRelease((WGPUBindGroup)(intptr_t)bindGroup);
    }

    // ── Command encoding / submission ────────────────────────────────────

    int64_t deviceCreateCommandEncoder(int64_t device,
                                       const std::string& label) override {
        WGPUCommandEncoderDescriptor wd = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
        wd.label = toView(label);
        WGPUCommandEncoder enc =
            wgpuDeviceCreateCommandEncoder((WGPUDevice)(intptr_t)device, &wd);
        if (!enc) throw std::runtime_error("wgpuDeviceCreateCommandEncoder failed");
        return (int64_t)(intptr_t)enc;
    }

    void commandEncoderRelease(int64_t encoder) override {
        wgpuCommandEncoderRelease((WGPUCommandEncoder)(intptr_t)encoder);
    }

    int64_t encoderBeginComputePass(int64_t encoder,
                                    NitroCppBuffer descriptor) override {
        const auto d = GpuComputePassDescriptor::fromNative(descriptor);
        WGPUComputePassDescriptor wd = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        WGPUPassTimestampWrites tw = {};
        if (d.timestampQuerySetAddress) {
            tw.querySet = (WGPUQuerySet)(intptr_t)d.timestampQuerySetAddress;
            tw.beginningOfPassWriteIndex = (uint32_t)d.timestampBeginIndex;
            tw.endOfPassWriteIndex = (uint32_t)d.timestampEndIndex;
            wd.timestampWrites = &tw;
        }
        WGPUComputePassEncoder pass = wgpuCommandEncoderBeginComputePass(
            (WGPUCommandEncoder)(intptr_t)encoder, &wd);
        if (!pass) throw std::runtime_error("encoderBeginComputePass failed");
        return (int64_t)(intptr_t)pass;
    }

    void computePassSetPipeline(int64_t pass, int64_t pipeline) override {
        wgpuComputePassEncoderSetPipeline(
            (WGPUComputePassEncoder)(intptr_t)pass,
            (WGPUComputePipeline)(intptr_t)pipeline);
    }

    void computePassSetBindGroup(int64_t pass, int64_t index,
                                 int64_t bindGroup) override {
        wgpuComputePassEncoderSetBindGroup(
            (WGPUComputePassEncoder)(intptr_t)pass, (uint32_t)index,
            (WGPUBindGroup)(intptr_t)bindGroup, 0, nullptr);
    }

    void computePassDispatchWorkgroups(int64_t pass, int64_t x, int64_t y,
                                       int64_t z) override {
        wgpuComputePassEncoderDispatchWorkgroups(
            (WGPUComputePassEncoder)(intptr_t)pass, (uint32_t)x, (uint32_t)y,
            (uint32_t)z);
    }

    void computePassEnd(int64_t pass) override {
        wgpuComputePassEncoderEnd((WGPUComputePassEncoder)(intptr_t)pass);
    }

    void computePassRelease(int64_t pass) override {
        wgpuComputePassEncoderRelease((WGPUComputePassEncoder)(intptr_t)pass);
    }

    void encoderCopyBufferToBuffer(int64_t encoder, int64_t src,
                                   int64_t srcOffset, int64_t dst,
                                   int64_t dstOffset, int64_t size) override {
        wgpuCommandEncoderCopyBufferToBuffer(
            (WGPUCommandEncoder)(intptr_t)encoder, (WGPUBuffer)(intptr_t)src,
            (uint64_t)srcOffset, (WGPUBuffer)(intptr_t)dst, (uint64_t)dstOffset,
            (uint64_t)size);
    }

    void encoderClearBuffer(int64_t encoder, int64_t buffer, int64_t offset,
                            int64_t size) override {
        wgpuCommandEncoderClearBuffer(
            (WGPUCommandEncoder)(intptr_t)encoder, (WGPUBuffer)(intptr_t)buffer,
            (uint64_t)offset, size < 0 ? WGPU_WHOLE_SIZE : (uint64_t)size);
    }

    void encoderWriteTimestamp(int64_t encoder, int64_t querySet,
                               int64_t queryIndex) override {
        wgpuCommandEncoderWriteTimestamp(
            (WGPUCommandEncoder)(intptr_t)encoder,
            (WGPUQuerySet)(intptr_t)querySet, (uint32_t)queryIndex);
    }

    void encoderPushDebugGroup(int64_t encoder,
                               const std::string& label) override {
        wgpuCommandEncoderPushDebugGroup((WGPUCommandEncoder)(intptr_t)encoder,
                                         toView(label));
    }

    void encoderPopDebugGroup(int64_t encoder) override {
        wgpuCommandEncoderPopDebugGroup((WGPUCommandEncoder)(intptr_t)encoder);
    }

    void encoderInsertDebugMarker(int64_t encoder,
                                  const std::string& label) override {
        wgpuCommandEncoderInsertDebugMarker(
            (WGPUCommandEncoder)(intptr_t)encoder, toView(label));
    }

    void renderPassPushDebugGroup(int64_t pass,
                                  const std::string& label) override {
        wgpuRenderPassEncoderPushDebugGroup(
            (WGPURenderPassEncoder)(intptr_t)pass, toView(label));
    }

    void renderPassPopDebugGroup(int64_t pass) override {
        wgpuRenderPassEncoderPopDebugGroup(
            (WGPURenderPassEncoder)(intptr_t)pass);
    }

    void renderPassInsertDebugMarker(int64_t pass,
                                     const std::string& label) override {
        wgpuRenderPassEncoderInsertDebugMarker(
            (WGPURenderPassEncoder)(intptr_t)pass, toView(label));
    }

    void computePassPushDebugGroup(int64_t pass,
                                   const std::string& label) override {
        wgpuComputePassEncoderPushDebugGroup(
            (WGPUComputePassEncoder)(intptr_t)pass, toView(label));
    }

    void computePassPopDebugGroup(int64_t pass) override {
        wgpuComputePassEncoderPopDebugGroup(
            (WGPUComputePassEncoder)(intptr_t)pass);
    }

    void computePassInsertDebugMarker(int64_t pass,
                                      const std::string& label) override {
        wgpuComputePassEncoderInsertDebugMarker(
            (WGPUComputePassEncoder)(intptr_t)pass, toView(label));
    }

    int64_t encoderFinish(int64_t encoder, const std::string& label) override {
        WGPUCommandBufferDescriptor wd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
        wd.label = toView(label);
        WGPUCommandBuffer cmd =
            wgpuCommandEncoderFinish((WGPUCommandEncoder)(intptr_t)encoder, &wd);
        if (!cmd) throw std::runtime_error("encoderFinish failed");
        return (int64_t)(intptr_t)cmd;
    }

    void commandBufferRelease(int64_t commandBuffer) override {
        wgpuCommandBufferRelease((WGPUCommandBuffer)(intptr_t)commandBuffer);
    }

    void queueSubmitOne(int64_t queue, int64_t commandBuffer) override {
        WGPUCommandBuffer cmd = (WGPUCommandBuffer)(intptr_t)commandBuffer;
        wgpuQueueSubmit((WGPUQueue)(intptr_t)queue, 1, &cmd);
    }

    void queueOnSubmittedWorkDone(int64_t queue, NitroError* _nitro_err,
                                  int64_t dartPort) override {
        auto* op = new PendingOp{_nitro_err, dartPort};
        WGPUQueueWorkDoneCallbackInfo cb = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
        cb.mode = WGPUCallbackMode_AllowProcessEvents;
        cb.userdata1 = op;
        cb.callback = [](WGPUQueueWorkDoneStatus status, WGPUStringView message,
                         void* ud1, void*) {
            auto* op = static_cast<PendingOp*>(ud1);
            if (status != WGPUQueueWorkDoneStatus_Success) {
                fillError(op->err, "GpuQueueError",
                          message.data ? toStd(message)
                                       : "onSubmittedWorkDone failed");
            }
            postNull(op->port);
            WgpuContext::get().opFinished();
            delete op;
        };
        wgpuQueueOnSubmittedWorkDone((WGPUQueue)(intptr_t)queue, cb);
        WgpuContext::get().opStarted();
    }

    // ── Textures / render passes ─────────────────────────────────────────

    int64_t deviceCreateTexture(int64_t device, NitroCppBuffer descriptor) override {
        const auto d = GpuTextureDescriptor::fromNative(descriptor);
        WGPUTextureDescriptor wd = WGPU_TEXTURE_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        wd.usage = (WGPUTextureUsage)d.usage;
        wd.dimension = (WGPUTextureDimension)d.dimension;
        wd.size = {(uint32_t)d.width, (uint32_t)d.height,
                   (uint32_t)d.depthOrArrayLayers};
        wd.format = (WGPUTextureFormat)d.format;
        wd.mipLevelCount = (uint32_t)d.mipLevelCount;
        wd.sampleCount = (uint32_t)d.sampleCount;
        WGPUTextureFormat viewFormat;
        if (d.viewFormat) {
            viewFormat = (WGPUTextureFormat)d.viewFormat;
            wd.viewFormatCount = 1;
            wd.viewFormats = &viewFormat;
        }
        WGPUTexture tex = wgpuDeviceCreateTexture((WGPUDevice)(intptr_t)device, &wd);
        if (!tex) throw std::runtime_error("wgpuDeviceCreateTexture failed");
        return (int64_t)(intptr_t)tex;
    }

    void textureDestroy(int64_t texture) override {
        wgpuTextureDestroy((WGPUTexture)(intptr_t)texture);
    }

    void textureRelease(int64_t texture) override {
        wgpuTextureRelease((WGPUTexture)(intptr_t)texture);
    }

    int64_t textureCreateView(int64_t texture,
                              NitroCppBuffer descriptor) override {
        const auto d = GpuTextureViewDescriptor::fromNative(descriptor);
        WGPUTextureViewDescriptor wd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        wd.baseMipLevel = (uint32_t)d.baseMipLevel;
        if (d.mipLevelCount > 0) wd.mipLevelCount = (uint32_t)d.mipLevelCount;
        if (d.dimension > 0) {
            wd.dimension = (WGPUTextureViewDimension)d.dimension;
        }
        wd.baseArrayLayer = (uint32_t)d.baseArrayLayer;
        if (d.arrayLayerCount > 0) {
            wd.arrayLayerCount = (uint32_t)d.arrayLayerCount;
        }
        if (d.format) wd.format = (WGPUTextureFormat)d.format;
        WGPUTextureView view =
            wgpuTextureCreateView((WGPUTexture)(intptr_t)texture, &wd);
        if (!view) throw std::runtime_error("wgpuTextureCreateView failed");
        return (int64_t)(intptr_t)view;
    }

    void textureViewRelease(int64_t view) override {
        wgpuTextureViewRelease((WGPUTextureView)(intptr_t)view);
    }

    int64_t textureGetWidth(int64_t texture) override {
        return wgpuTextureGetWidth((WGPUTexture)(intptr_t)texture);
    }
    int64_t textureGetHeight(int64_t texture) override {
        return wgpuTextureGetHeight((WGPUTexture)(intptr_t)texture);
    }
    int64_t textureGetDepthOrArrayLayers(int64_t texture) override {
        return wgpuTextureGetDepthOrArrayLayers((WGPUTexture)(intptr_t)texture);
    }
    int64_t textureGetFormat(int64_t texture) override {
        return (int64_t)wgpuTextureGetFormat((WGPUTexture)(intptr_t)texture);
    }
    int64_t textureGetDimension(int64_t texture) override {
        return (int64_t)wgpuTextureGetDimension((WGPUTexture)(intptr_t)texture);
    }
    int64_t textureGetMipLevelCount(int64_t texture) override {
        return wgpuTextureGetMipLevelCount((WGPUTexture)(intptr_t)texture);
    }
    int64_t textureGetSampleCount(int64_t texture) override {
        return wgpuTextureGetSampleCount((WGPUTexture)(intptr_t)texture);
    }
    int64_t textureGetUsage(int64_t texture) override {
        return (int64_t)wgpuTextureGetUsage((WGPUTexture)(intptr_t)texture);
    }

    void queueWriteTexture(int64_t queue, int64_t texture, const uint8_t* data,
                           size_t data_length, int64_t bytesPerRow,
                           int64_t width, int64_t height, int64_t mipLevel,
                           int64_t arrayLayer, int64_t originX,
                           int64_t originY) override {
        WGPUTexelCopyTextureInfo dst = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
        dst.texture = (WGPUTexture)(intptr_t)texture;
        dst.mipLevel = (uint32_t)mipLevel;
        dst.origin = {(uint32_t)originX, (uint32_t)originY,
                      (uint32_t)arrayLayer};
        WGPUTexelCopyBufferLayout layout = {};
        layout.offset = 0;
        layout.bytesPerRow = (uint32_t)bytesPerRow;
        layout.rowsPerImage = (uint32_t)height;
        WGPUExtent3D extent = {(uint32_t)width, (uint32_t)height, 1};
        wgpuQueueWriteTexture((WGPUQueue)(intptr_t)queue, &dst, data,
                              data_length, &layout, &extent);
    }

    int64_t deviceCreateSampler(int64_t device,
                                NitroCppBuffer descriptor) override {
        const auto d = GpuSamplerDescriptor::fromNative(descriptor);
        WGPUSamplerDescriptor wd = WGPU_SAMPLER_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        wd.magFilter = (WGPUFilterMode)d.magFilter;
        wd.minFilter = (WGPUFilterMode)d.minFilter;
        wd.mipmapFilter = (WGPUMipmapFilterMode)d.mipmapFilter;
        wd.addressModeU = (WGPUAddressMode)d.addressModeU;
        wd.addressModeV = (WGPUAddressMode)d.addressModeV;
        wd.addressModeW = (WGPUAddressMode)d.addressModeW;
        if (d.compare) wd.compare = (WGPUCompareFunction)d.compare;
        wd.lodMinClamp = (float)d.lodMinClamp;
        wd.lodMaxClamp = (float)d.lodMaxClamp;
        wd.maxAnisotropy = (uint16_t)d.maxAnisotropy;
        WGPUSampler sampler =
            wgpuDeviceCreateSampler((WGPUDevice)(intptr_t)device, &wd);
        if (!sampler) throw std::runtime_error("wgpuDeviceCreateSampler failed");
        return (int64_t)(intptr_t)sampler;
    }

    void samplerRelease(int64_t sampler) override {
        wgpuSamplerRelease((WGPUSampler)(intptr_t)sampler);
    }

    int64_t deviceCreateRenderPipeline(int64_t device,
                                       NitroCppBuffer descriptor) override {
        const auto d = GpuRenderPipelineDescriptor::fromNative(descriptor);

        WGPUColorTargetState target = WGPU_COLOR_TARGET_STATE_INIT;
        target.format = (WGPUTextureFormat)d.targetFormat;

        // Blend: a custom state (colorBlendOp != 0) wins over the presets
        // (1 = classic alpha, 2 = additive, 3 = premultiplied). The blend
        // state and write mask apply to every color target.
        WGPUBlendState blend = WGPU_BLEND_STATE_INIT;
        bool hasBlend = true;
        if (d.colorBlendOp != 0) {
            blend.color = {(WGPUBlendOperation)d.colorBlendOp,
                           (WGPUBlendFactor)d.colorBlendSrc,
                           (WGPUBlendFactor)d.colorBlendDst};
            blend.alpha = {(WGPUBlendOperation)d.alphaBlendOp,
                           (WGPUBlendFactor)d.alphaBlendSrc,
                           (WGPUBlendFactor)d.alphaBlendDst};
        } else if (d.blendMode == 1) {
            blend.color = {WGPUBlendOperation_Add, WGPUBlendFactor_SrcAlpha,
                           WGPUBlendFactor_OneMinusSrcAlpha};
            blend.alpha = {WGPUBlendOperation_Add, WGPUBlendFactor_One,
                           WGPUBlendFactor_OneMinusSrcAlpha};
        } else if (d.blendMode == 2) {
            blend.color = {WGPUBlendOperation_Add, WGPUBlendFactor_One,
                           WGPUBlendFactor_One};
            blend.alpha = {WGPUBlendOperation_Add, WGPUBlendFactor_One,
                           WGPUBlendFactor_One};
        } else if (d.blendMode == 3) {
            blend.color = {WGPUBlendOperation_Add, WGPUBlendFactor_One,
                           WGPUBlendFactor_OneMinusSrcAlpha};
            blend.alpha = {WGPUBlendOperation_Add, WGPUBlendFactor_One,
                           WGPUBlendFactor_OneMinusSrcAlpha};
        } else {
            hasBlend = false;
        }
        if (hasBlend) target.blend = &blend;
        if (d.writeMask >= 0) {
            target.writeMask = (WGPUColorWriteMask)d.writeMask;
        }

        WGPUColorTargetState targets[8];
        targets[0] = target;
        size_t targetCount = 1;
        const int64_t extraFormats[7] = {
            d.targetFormat1, d.targetFormat2, d.targetFormat3,
            d.targetFormat4, d.targetFormat5, d.targetFormat6,
            d.targetFormat7};
        for (int i = 0; i < 7 && extraFormats[i]; i++) {
            WGPUColorTargetState extra = WGPU_COLOR_TARGET_STATE_INIT;
            extra.format = (WGPUTextureFormat)extraFormats[i];
            if (hasBlend) extra.blend = &blend;
            if (d.writeMask >= 0) {
                extra.writeMask = (WGPUColorWriteMask)d.writeMask;
            }
            targets[targetCount++] = extra;
        }

        WGPUFragmentState fragment = WGPU_FRAGMENT_STATE_INIT;
        fragment.module = (WGPUShaderModule)(intptr_t)d.moduleAddress;
        fragment.entryPoint = toView(d.fragmentEntryPoint);
        fragment.targetCount = targetCount;
        fragment.targets = targets;

        // Vertex buffer layouts (attribute arrays must outlive the create).
        std::vector<std::vector<WGPUVertexAttribute>> attrStorage;
        std::vector<WGPUVertexBufferLayout> layouts;
        attrStorage.reserve(d.vertexBuffers.size());
        layouts.reserve(d.vertexBuffers.size());
        for (const auto& vb : d.vertexBuffers) {
            std::vector<WGPUVertexAttribute> attrs;
            attrs.reserve(vb.attributes.size());
            for (const auto& a : vb.attributes) {
                WGPUVertexAttribute wa = WGPU_VERTEX_ATTRIBUTE_INIT;
                wa.format = (WGPUVertexFormat)a.format;
                wa.offset = (uint64_t)a.offset;
                wa.shaderLocation = (uint32_t)a.shaderLocation;
                attrs.push_back(wa);
            }
            attrStorage.push_back(std::move(attrs));
            WGPUVertexBufferLayout wl = WGPU_VERTEX_BUFFER_LAYOUT_INIT;
            wl.arrayStride = (uint64_t)vb.arrayStride;
            wl.stepMode = (WGPUVertexStepMode)vb.stepMode;
            wl.attributeCount = attrStorage.back().size();
            wl.attributes = attrStorage.back().data();
            layouts.push_back(wl);
        }

        WGPURenderPipelineDescriptor wd = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        wd.layout = d.layoutAddress
                        ? (WGPUPipelineLayout)(intptr_t)d.layoutAddress
                        : nullptr;
        wd.vertex.module = (WGPUShaderModule)(intptr_t)d.moduleAddress;
        wd.vertex.entryPoint = toView(d.vertexEntryPoint);
        wd.vertex.bufferCount = layouts.size();
        wd.vertex.buffers = layouts.empty() ? nullptr : layouts.data();
        wd.primitive.topology = (WGPUPrimitiveTopology)d.topology;
        wd.primitive.cullMode = (WGPUCullMode)d.cullMode;
        wd.primitive.frontFace = (WGPUFrontFace)d.frontFace;
        wd.primitive.stripIndexFormat = (WGPUIndexFormat)d.stripIndexFormat;
        wd.multisample.count = (uint32_t)d.sampleCount;
        wd.multisample.mask = d.multisampleMask < 0
                                  ? 0xFFFFFFFFu
                                  : (uint32_t)d.multisampleMask;
        wd.multisample.alphaToCoverageEnabled =
            d.alphaToCoverageEnabled ? 1 : 0;
        wd.fragment = &fragment;

        WGPUDepthStencilState depth = WGPU_DEPTH_STENCIL_STATE_INIT;
        if (d.depthFormat) {
            depth.format = (WGPUTextureFormat)d.depthFormat;
            depth.depthWriteEnabled = d.depthWriteEnabled
                                          ? WGPUOptionalBool_True
                                          : WGPUOptionalBool_False;
            depth.depthCompare = (WGPUCompareFunction)d.depthCompare;
            depth.depthBias = (int32_t)d.depthBias;
            depth.depthBiasSlopeScale = (float)d.depthBiasSlopeScale;
            depth.depthBiasClamp = (float)d.depthBiasClamp;
            depth.stencilReadMask = d.stencilReadMask < 0
                                        ? 0xFFFFFFFFu
                                        : (uint32_t)d.stencilReadMask;
            depth.stencilWriteMask = d.stencilWriteMask < 0
                                         ? 0xFFFFFFFFu
                                         : (uint32_t)d.stencilWriteMask;
            WGPUStencilFaceState face = {};
            face.compare = (WGPUCompareFunction)d.stencilCompare;
            face.failOp = (WGPUStencilOperation)d.stencilFailOp;
            face.depthFailOp = (WGPUStencilOperation)d.stencilDepthFailOp;
            face.passOp = (WGPUStencilOperation)d.stencilPassOp;
            depth.stencilFront = face;
            WGPUStencilFaceState back = face;
            if (d.stencilBackCompare != 0) {
                back.compare = (WGPUCompareFunction)d.stencilBackCompare;
                back.failOp = (WGPUStencilOperation)(
                    d.stencilBackFailOp ? d.stencilBackFailOp : 1);
                back.depthFailOp = (WGPUStencilOperation)(
                    d.stencilBackDepthFailOp ? d.stencilBackDepthFailOp : 1);
                back.passOp = (WGPUStencilOperation)(
                    d.stencilBackPassOp ? d.stencilBackPassOp : 1);
            }
            depth.stencilBack = back;
            wd.depthStencil = &depth;
        }

        WGPURenderPipeline p =
            wgpuDeviceCreateRenderPipeline((WGPUDevice)(intptr_t)device, &wd);
        if (!p) throw std::runtime_error("wgpuDeviceCreateRenderPipeline failed");
        return (int64_t)(intptr_t)p;
    }

    void renderPipelineRelease(int64_t pipeline) override {
        wgpuRenderPipelineRelease((WGPURenderPipeline)(intptr_t)pipeline);
    }

    int64_t renderPipelineGetBindGroupLayout(int64_t pipeline,
                                             int64_t groupIndex) override {
        WGPUBindGroupLayout layout = wgpuRenderPipelineGetBindGroupLayout(
            (WGPURenderPipeline)(intptr_t)pipeline, (uint32_t)groupIndex);
        if (!layout) {
            throw std::runtime_error("renderPipelineGetBindGroupLayout failed");
        }
        return (int64_t)(intptr_t)layout;
    }

    int64_t encoderBeginRenderPass(int64_t encoder,
                                   NitroCppBuffer descriptor) override {
        const auto d = GpuRenderPassDescriptor::fromNative(descriptor);
        std::vector<WGPURenderPassColorAttachment> attachments(
            d.colorAttachments.size());
        for (size_t i = 0; i < d.colorAttachments.size(); i++) {
            const auto& a = d.colorAttachments[i];
            attachments[i] = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
            attachments[i].view = (WGPUTextureView)(intptr_t)a.viewAddress;
            attachments[i].loadOp = (WGPULoadOp)a.loadOp;
            attachments[i].storeOp = (WGPUStoreOp)a.storeOp;
            attachments[i].clearValue = {a.clearR, a.clearG, a.clearB, a.clearA};
            if (a.resolveTargetAddress) {
                attachments[i].resolveTarget =
                    (WGPUTextureView)(intptr_t)a.resolveTargetAddress;
            }
        }
        WGPURenderPassDescriptor wd = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        wd.colorAttachmentCount = attachments.size();
        wd.colorAttachments = attachments.data();
        WGPURenderPassDepthStencilAttachment depth =
            WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
        if (d.depthViewAddress) {
            depth.view = (WGPUTextureView)(intptr_t)d.depthViewAddress;
            if (d.depthReadOnly) {
                depth.depthReadOnly = 1;  // ops must stay Undefined
            } else {
                depth.depthLoadOp = (WGPULoadOp)d.depthLoadOp;
                depth.depthStoreOp = (WGPUStoreOp)d.depthStoreOp;
                depth.depthClearValue = (float)d.depthClearValue;
            }
            if (d.stencilReadOnly) {
                depth.stencilReadOnly = 1;
            } else if (d.stencilLoadOp) {
                depth.stencilLoadOp = (WGPULoadOp)d.stencilLoadOp;
                depth.stencilStoreOp = (WGPUStoreOp)d.stencilStoreOp;
                depth.stencilClearValue = (uint32_t)d.stencilClearValue;
            }
            wd.depthStencilAttachment = &depth;
        }
        if (d.occlusionQuerySetAddress) {
            wd.occlusionQuerySet =
                (WGPUQuerySet)(intptr_t)d.occlusionQuerySetAddress;
        }
        WGPUPassTimestampWrites tw = {};
        if (d.timestampQuerySetAddress) {
            tw.querySet = (WGPUQuerySet)(intptr_t)d.timestampQuerySetAddress;
            tw.beginningOfPassWriteIndex = (uint32_t)d.timestampBeginIndex;
            tw.endOfPassWriteIndex = (uint32_t)d.timestampEndIndex;
            wd.timestampWrites = &tw;
        }
        WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(
            (WGPUCommandEncoder)(intptr_t)encoder, &wd);
        if (!pass) throw std::runtime_error("encoderBeginRenderPass failed");
        return (int64_t)(intptr_t)pass;
    }

    void renderPassSetPipeline(int64_t pass, int64_t pipeline) override {
        wgpuRenderPassEncoderSetPipeline(
            (WGPURenderPassEncoder)(intptr_t)pass,
            (WGPURenderPipeline)(intptr_t)pipeline);
    }

    void renderPassSetBindGroup(int64_t pass, int64_t index,
                                int64_t bindGroup) override {
        wgpuRenderPassEncoderSetBindGroup(
            (WGPURenderPassEncoder)(intptr_t)pass, (uint32_t)index,
            (WGPUBindGroup)(intptr_t)bindGroup, 0, nullptr);
    }

    void renderPassSetVertexBuffer(int64_t pass, int64_t slot, int64_t buffer,
                                   int64_t offset) override {
        wgpuRenderPassEncoderSetVertexBuffer(
            (WGPURenderPassEncoder)(intptr_t)pass, (uint32_t)slot,
            (WGPUBuffer)(intptr_t)buffer, (uint64_t)offset, WGPU_WHOLE_SIZE);
    }

    void renderPassSetIndexBuffer(int64_t pass, int64_t buffer,
                                  int64_t indexFormat, int64_t offset) override {
        wgpuRenderPassEncoderSetIndexBuffer(
            (WGPURenderPassEncoder)(intptr_t)pass,
            (WGPUBuffer)(intptr_t)buffer, (WGPUIndexFormat)indexFormat,
            (uint64_t)offset, WGPU_WHOLE_SIZE);
    }

    void renderPassDrawIndexed(int64_t pass, int64_t indexCount,
                               int64_t instanceCount, int64_t firstIndex,
                               int64_t baseVertex,
                               int64_t firstInstance) override {
        wgpuRenderPassEncoderDrawIndexed(
            (WGPURenderPassEncoder)(intptr_t)pass, (uint32_t)indexCount,
            (uint32_t)instanceCount, (uint32_t)firstIndex,
            (int32_t)baseVertex, (uint32_t)firstInstance);
    }

    // ── Explicit layouts ─────────────────────────────────────────────────

    int64_t deviceCreateBindGroupLayout(int64_t device,
                                        NitroCppBuffer descriptor) override {
        const auto d = GpuBindGroupLayoutDescriptor::fromNative(descriptor);
        std::vector<WGPUBindGroupLayoutEntry> entries;
        entries.reserve(d.entries.size());
        for (const auto& e : d.entries) {
            WGPUBindGroupLayoutEntry we = WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT;
            we.binding = (uint32_t)e.binding;
            we.visibility = (WGPUShaderStage)e.visibility;
            switch (e.type) {
                case 1:
                    we.buffer.type = WGPUBufferBindingType_Uniform;
                    we.buffer.hasDynamicOffset = e.hasDynamicOffset ? 1 : 0;
                    break;
                case 2:
                    we.buffer.type = WGPUBufferBindingType_Storage;
                    we.buffer.hasDynamicOffset = e.hasDynamicOffset ? 1 : 0;
                    break;
                case 3:
                    we.buffer.type = WGPUBufferBindingType_ReadOnlyStorage;
                    we.buffer.hasDynamicOffset = e.hasDynamicOffset ? 1 : 0;
                    break;
                case 4:
                    we.sampler.type = (WGPUSamplerBindingType)e.samplerType;
                    break;
                case 5:
                    we.texture.sampleType = (WGPUTextureSampleType)e.sampleType;
                    we.texture.viewDimension =
                        (WGPUTextureViewDimension)e.viewDimension;
                    we.texture.multisampled = e.multisampled ? 1 : 0;
                    break;
                case 6:
                    we.storageTexture.access = WGPUStorageTextureAccess_WriteOnly;
                    we.storageTexture.format = WGPUTextureFormat_RGBA8Unorm;
                    we.storageTexture.viewDimension = WGPUTextureViewDimension_2D;
                    break;
                default:
                    throw std::runtime_error(
                        "GpuBindGroupLayoutEntry.type must be 1..6");
            }
            entries.push_back(we);
        }
        WGPUBindGroupLayoutDescriptor wd = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        wd.entryCount = entries.size();
        wd.entries = entries.data();
        WGPUBindGroupLayout layout =
            wgpuDeviceCreateBindGroupLayout((WGPUDevice)(intptr_t)device, &wd);
        if (!layout) {
            throw std::runtime_error("wgpuDeviceCreateBindGroupLayout failed");
        }
        return (int64_t)(intptr_t)layout;
    }

    int64_t deviceCreatePipelineLayout(int64_t device,
                                       NitroCppBuffer descriptor) override {
        const auto d = GpuPipelineLayoutDescriptor::fromNative(descriptor);
        WGPUBindGroupLayout layouts[8];
        size_t count = 0;
        const int64_t addrs[8] = {d.layout0, d.layout1, d.layout2, d.layout3,
                                  d.layout4, d.layout5, d.layout6, d.layout7};
        for (int i = 0; i < 8 && addrs[i]; i++) {
            layouts[count++] = (WGPUBindGroupLayout)(intptr_t)addrs[i];
        }
        WGPUPipelineLayoutDescriptor wd = WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        wd.bindGroupLayoutCount = count;
        wd.bindGroupLayouts = count ? layouts : nullptr;
        WGPUPipelineLayout layout =
            wgpuDeviceCreatePipelineLayout((WGPUDevice)(intptr_t)device, &wd);
        if (!layout) {
            throw std::runtime_error("wgpuDeviceCreatePipelineLayout failed");
        }
        return (int64_t)(intptr_t)layout;
    }

    void pipelineLayoutRelease(int64_t layout) override {
        wgpuPipelineLayoutRelease((WGPUPipelineLayout)(intptr_t)layout);
    }

    void renderPassDraw(int64_t pass, int64_t vertexCount, int64_t instanceCount,
                        int64_t firstVertex, int64_t firstInstance) override {
        wgpuRenderPassEncoderDraw((WGPURenderPassEncoder)(intptr_t)pass,
                                  (uint32_t)vertexCount, (uint32_t)instanceCount,
                                  (uint32_t)firstVertex, (uint32_t)firstInstance);
    }

    void renderPassEnd(int64_t pass) override {
        wgpuRenderPassEncoderEnd((WGPURenderPassEncoder)(intptr_t)pass);
    }

    void renderPassRelease(int64_t pass) override {
        wgpuRenderPassEncoderRelease((WGPURenderPassEncoder)(intptr_t)pass);
    }

    void encoderCopyBufferToTexture(int64_t encoder, int64_t buffer,
                                    int64_t bytesPerRow, int64_t texture,
                                    int64_t mipLevel, int64_t width,
                                    int64_t height, int64_t bufferOffset,
                                    int64_t originX, int64_t originY,
                                    int64_t originZ) override {
        WGPUTexelCopyBufferInfo src = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
        src.buffer = (WGPUBuffer)(intptr_t)buffer;
        src.layout.offset = (uint64_t)bufferOffset;
        src.layout.bytesPerRow = (uint32_t)bytesPerRow;
        src.layout.rowsPerImage = (uint32_t)height;
        WGPUTexelCopyTextureInfo dst = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
        dst.texture = (WGPUTexture)(intptr_t)texture;
        dst.mipLevel = (uint32_t)mipLevel;
        dst.origin = {(uint32_t)originX, (uint32_t)originY, (uint32_t)originZ};
        WGPUExtent3D extent = {(uint32_t)width, (uint32_t)height, 1};
        wgpuCommandEncoderCopyBufferToTexture(
            (WGPUCommandEncoder)(intptr_t)encoder, &src, &dst, &extent);
    }

    void encoderCopyTextureToTexture(int64_t encoder, int64_t srcTexture,
                                     int64_t dstTexture, int64_t width,
                                     int64_t height, int64_t depth,
                                     int64_t srcMip, int64_t srcX,
                                     int64_t srcY, int64_t srcZ,
                                     int64_t dstMip, int64_t dstX,
                                     int64_t dstY, int64_t dstZ) override {
        WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
        src.texture = (WGPUTexture)(intptr_t)srcTexture;
        src.mipLevel = (uint32_t)srcMip;
        src.origin = {(uint32_t)srcX, (uint32_t)srcY, (uint32_t)srcZ};
        WGPUTexelCopyTextureInfo dst = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
        dst.texture = (WGPUTexture)(intptr_t)dstTexture;
        dst.mipLevel = (uint32_t)dstMip;
        dst.origin = {(uint32_t)dstX, (uint32_t)dstY, (uint32_t)dstZ};
        WGPUExtent3D extent = {(uint32_t)width, (uint32_t)height,
                               (uint32_t)depth};
        wgpuCommandEncoderCopyTextureToTexture(
            (WGPUCommandEncoder)(intptr_t)encoder, &src, &dst, &extent);
    }

    // ── Render pass state ────────────────────────────────────────────────

    void renderPassSetViewport(int64_t pass, double x, double y, double width,
                               double height, double minDepth,
                               double maxDepth) override {
        wgpuRenderPassEncoderSetViewport(
            (WGPURenderPassEncoder)(intptr_t)pass, (float)x, (float)y,
            (float)width, (float)height, (float)minDepth, (float)maxDepth);
    }

    void renderPassSetScissorRect(int64_t pass, int64_t x, int64_t y,
                                  int64_t width, int64_t height) override {
        wgpuRenderPassEncoderSetScissorRect(
            (WGPURenderPassEncoder)(intptr_t)pass, (uint32_t)x, (uint32_t)y,
            (uint32_t)width, (uint32_t)height);
    }

    void renderPassSetBlendConstant(int64_t pass, double r, double g, double b,
                                    double a) override {
        WGPUColor color = {r, g, b, a};
        wgpuRenderPassEncoderSetBlendConstant(
            (WGPURenderPassEncoder)(intptr_t)pass, &color);
    }

    // ── Indirect execution ───────────────────────────────────────────────

    void renderPassDrawIndirect(int64_t pass, int64_t buffer,
                                int64_t offset) override {
        wgpuRenderPassEncoderDrawIndirect(
            (WGPURenderPassEncoder)(intptr_t)pass,
            (WGPUBuffer)(intptr_t)buffer, (uint64_t)offset);
    }

    void renderPassDrawIndexedIndirect(int64_t pass, int64_t buffer,
                                       int64_t offset) override {
        wgpuRenderPassEncoderDrawIndexedIndirect(
            (WGPURenderPassEncoder)(intptr_t)pass,
            (WGPUBuffer)(intptr_t)buffer, (uint64_t)offset);
    }

    void computePassDispatchWorkgroupsIndirect(int64_t pass, int64_t buffer,
                                               int64_t offset) override {
        wgpuComputePassEncoderDispatchWorkgroupsIndirect(
            (WGPUComputePassEncoder)(intptr_t)pass,
            (WGPUBuffer)(intptr_t)buffer, (uint64_t)offset);
    }

    // ── Occlusion / stencil / dynamic offsets ────────────────────────────

    int64_t deviceCreateOcclusionQuerySet(int64_t device,
                                          int64_t count) override {
        WGPUQuerySetDescriptor wd = WGPU_QUERY_SET_DESCRIPTOR_INIT;
        wd.label = {"occlusion_query_set", WGPU_STRLEN};
        wd.type = WGPUQueryType_Occlusion;
        wd.count = (uint32_t)count;
        WGPUQuerySet qs =
            wgpuDeviceCreateQuerySet((WGPUDevice)(intptr_t)device, &wd);
        if (!qs) throw std::runtime_error("wgpuDeviceCreateQuerySet failed");
        return (int64_t)(intptr_t)qs;
    }

    NitroCppBuffer deviceGetLimits(int64_t device) override {
        WGPULimits limits = WGPU_LIMITS_INIT;
        if (wgpuDeviceGetLimits((WGPUDevice)(intptr_t)device, &limits) !=
            WGPUStatus_Success) {
            throw std::runtime_error("wgpuDeviceGetLimits failed");
        }
        GpuLimits out;
        fillLimits(limits, out);
        return out.toNativeBuffer();
    }

    void renderPassBeginOcclusionQuery(int64_t pass,
                                       int64_t queryIndex) override {
        wgpuRenderPassEncoderBeginOcclusionQuery(
            (WGPURenderPassEncoder)(intptr_t)pass, (uint32_t)queryIndex);
    }

    void renderPassEndOcclusionQuery(int64_t pass) override {
        wgpuRenderPassEncoderEndOcclusionQuery(
            (WGPURenderPassEncoder)(intptr_t)pass);
    }

    void renderPassSetStencilReference(int64_t pass,
                                       int64_t reference) override {
        wgpuRenderPassEncoderSetStencilReference(
            (WGPURenderPassEncoder)(intptr_t)pass, (uint32_t)reference);
    }

    void renderPassSetBindGroupOffsets(int64_t pass, int64_t index,
                                       int64_t bindGroup, int64_t offsetCount,
                                       int64_t o0, int64_t o1, int64_t o2,
                                       int64_t o3, int64_t o4, int64_t o5,
                                       int64_t o6, int64_t o7) override {
        const uint32_t offsets[8] = {(uint32_t)o0, (uint32_t)o1, (uint32_t)o2,
                                     (uint32_t)o3, (uint32_t)o4, (uint32_t)o5,
                                     (uint32_t)o6, (uint32_t)o7};
        wgpuRenderPassEncoderSetBindGroup(
            (WGPURenderPassEncoder)(intptr_t)pass, (uint32_t)index,
            (WGPUBindGroup)(intptr_t)bindGroup, (size_t)offsetCount, offsets);
    }

    void computePassSetBindGroupOffsets(int64_t pass, int64_t index,
                                        int64_t bindGroup, int64_t offsetCount,
                                        int64_t o0, int64_t o1, int64_t o2,
                                        int64_t o3, int64_t o4, int64_t o5,
                                        int64_t o6, int64_t o7) override {
        const uint32_t offsets[8] = {(uint32_t)o0, (uint32_t)o1, (uint32_t)o2,
                                     (uint32_t)o3, (uint32_t)o4, (uint32_t)o5,
                                     (uint32_t)o6, (uint32_t)o7};
        wgpuComputePassEncoderSetBindGroup(
            (WGPUComputePassEncoder)(intptr_t)pass, (uint32_t)index,
            (WGPUBindGroup)(intptr_t)bindGroup, (size_t)offsetCount, offsets);
    }

    // ── Render bundles ───────────────────────────────────────────────────

    int64_t deviceCreateRenderBundleEncoder(int64_t device,
                                            NitroCppBuffer descriptor) override {
        const auto d = GpuRenderBundleEncoderDescriptor::fromNative(descriptor);
        WGPUTextureFormat formats[8];
        size_t count = 0;
        const int64_t f[8] = {d.format0, d.format1, d.format2, d.format3,
                              d.format4, d.format5, d.format6, d.format7};
        for (int i = 0; i < 8 && f[i]; i++) {
            formats[count++] = (WGPUTextureFormat)f[i];
        }
        WGPURenderBundleEncoderDescriptor wd = {};
        std::string label = d.label;
        wd.label = toView(label);
        wd.colorFormatCount = count;
        wd.colorFormats = formats;
        wd.depthStencilFormat = (WGPUTextureFormat)d.depthFormat;
        wd.sampleCount = (uint32_t)d.sampleCount;
        wd.depthReadOnly = d.depthReadOnly ? 1 : 0;
        wd.stencilReadOnly = d.stencilReadOnly ? 1 : 0;
        WGPURenderBundleEncoder enc = wgpuDeviceCreateRenderBundleEncoder(
            (WGPUDevice)(intptr_t)device, &wd);
        if (!enc) {
            throw std::runtime_error("wgpuDeviceCreateRenderBundleEncoder failed");
        }
        return (int64_t)(intptr_t)enc;
    }

    void bundleSetPipeline(int64_t bundleEncoder, int64_t pipeline) override {
        wgpuRenderBundleEncoderSetPipeline(
            (WGPURenderBundleEncoder)(intptr_t)bundleEncoder,
            (WGPURenderPipeline)(intptr_t)pipeline);
    }

    void bundleSetBindGroup(int64_t bundleEncoder, int64_t index,
                            int64_t bindGroup) override {
        wgpuRenderBundleEncoderSetBindGroup(
            (WGPURenderBundleEncoder)(intptr_t)bundleEncoder, (uint32_t)index,
            (WGPUBindGroup)(intptr_t)bindGroup, 0, nullptr);
    }

    void bundleSetVertexBuffer(int64_t bundleEncoder, int64_t slot,
                               int64_t buffer, int64_t offset) override {
        wgpuRenderBundleEncoderSetVertexBuffer(
            (WGPURenderBundleEncoder)(intptr_t)bundleEncoder, (uint32_t)slot,
            (WGPUBuffer)(intptr_t)buffer, (uint64_t)offset, WGPU_WHOLE_SIZE);
    }

    void bundleSetIndexBuffer(int64_t bundleEncoder, int64_t buffer,
                              int64_t indexFormat, int64_t offset) override {
        wgpuRenderBundleEncoderSetIndexBuffer(
            (WGPURenderBundleEncoder)(intptr_t)bundleEncoder,
            (WGPUBuffer)(intptr_t)buffer, (WGPUIndexFormat)indexFormat,
            (uint64_t)offset, WGPU_WHOLE_SIZE);
    }

    void bundleDraw(int64_t bundleEncoder, int64_t vertexCount,
                    int64_t instanceCount, int64_t firstVertex,
                    int64_t firstInstance) override {
        wgpuRenderBundleEncoderDraw(
            (WGPURenderBundleEncoder)(intptr_t)bundleEncoder,
            (uint32_t)vertexCount, (uint32_t)instanceCount,
            (uint32_t)firstVertex, (uint32_t)firstInstance);
    }

    void bundleDrawIndexed(int64_t bundleEncoder, int64_t indexCount,
                           int64_t instanceCount, int64_t firstIndex,
                           int64_t baseVertex, int64_t firstInstance) override {
        wgpuRenderBundleEncoderDrawIndexed(
            (WGPURenderBundleEncoder)(intptr_t)bundleEncoder,
            (uint32_t)indexCount, (uint32_t)instanceCount,
            (uint32_t)firstIndex, (int32_t)baseVertex,
            (uint32_t)firstInstance);
    }

    void bundleDrawIndirect(int64_t bundleEncoder, int64_t buffer,
                            int64_t offset) override {
        wgpuRenderBundleEncoderDrawIndirect(
            (WGPURenderBundleEncoder)(intptr_t)bundleEncoder,
            (WGPUBuffer)(intptr_t)buffer, (uint64_t)offset);
    }

    void bundleDrawIndexedIndirect(int64_t bundleEncoder, int64_t buffer,
                                   int64_t offset) override {
        wgpuRenderBundleEncoderDrawIndexedIndirect(
            (WGPURenderBundleEncoder)(intptr_t)bundleEncoder,
            (WGPUBuffer)(intptr_t)buffer, (uint64_t)offset);
    }

    int64_t bundleFinish(int64_t bundleEncoder,
                         const std::string& label) override {
        WGPURenderBundleDescriptor wd = {};
        wd.label = toView(label);
        WGPURenderBundle bundle = wgpuRenderBundleEncoderFinish(
            (WGPURenderBundleEncoder)(intptr_t)bundleEncoder, &wd);
        if (!bundle) throw std::runtime_error("bundleFinish failed");
        return (int64_t)(intptr_t)bundle;
    }

    void renderBundleEncoderRelease(int64_t bundleEncoder) override {
        wgpuRenderBundleEncoderRelease(
            (WGPURenderBundleEncoder)(intptr_t)bundleEncoder);
    }

    void renderBundleRelease(int64_t bundle) override {
        wgpuRenderBundleRelease((WGPURenderBundle)(intptr_t)bundle);
    }

    void renderPassExecuteBundle(int64_t pass, int64_t bundle) override {
        WGPURenderBundle b = (WGPURenderBundle)(intptr_t)bundle;
        wgpuRenderPassEncoderExecuteBundles(
            (WGPURenderPassEncoder)(intptr_t)pass, 1, &b);
    }

    // ── Timestamp queries ────────────────────────────────────────────────

    int64_t deviceCreateTimestampQuerySet(int64_t device, int64_t count) override {
        WGPUQuerySetDescriptor wd = WGPU_QUERY_SET_DESCRIPTOR_INIT;
        wd.label = {"timestamp_query_set", WGPU_STRLEN};
        wd.type = WGPUQueryType_Timestamp;
        wd.count = (uint32_t)count;
        WGPUQuerySet qs =
            wgpuDeviceCreateQuerySet((WGPUDevice)(intptr_t)device, &wd);
        if (!qs) throw std::runtime_error("wgpuDeviceCreateQuerySet failed");
        return (int64_t)(intptr_t)qs;
    }

    void querySetRelease(int64_t querySet) override {
        wgpuQuerySetRelease((WGPUQuerySet)(intptr_t)querySet);
    }

    int64_t querySetGetCount(int64_t querySet) override {
        return wgpuQuerySetGetCount((WGPUQuerySet)(intptr_t)querySet);
    }
    int64_t querySetGetType(int64_t querySet) override {
        return (int64_t)wgpuQuerySetGetType((WGPUQuerySet)(intptr_t)querySet);
    }

    void encoderResolveQuerySet(int64_t encoder, int64_t querySet,
                                int64_t firstQuery, int64_t queryCount,
                                int64_t destination,
                                int64_t destinationOffset) override {
        wgpuCommandEncoderResolveQuerySet(
            (WGPUCommandEncoder)(intptr_t)encoder,
            (WGPUQuerySet)(intptr_t)querySet, (uint32_t)firstQuery,
            (uint32_t)queryCount, (WGPUBuffer)(intptr_t)destination,
            (uint64_t)destinationOffset);
    }

    double queueTimestampPeriod(int64_t queue) override {
        return (double)wgpuQueueGetTimestampPeriod((WGPUQueue)(intptr_t)queue);
    }

    void encoderCopyTextureToBuffer(int64_t encoder, int64_t texture,
                                    int64_t buffer, int64_t bytesPerRow,
                                    int64_t width, int64_t height,
                                    int64_t mipLevel, int64_t originX,
                                    int64_t originY, int64_t originZ,
                                    int64_t bufferOffset) override {
        WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
        src.texture = (WGPUTexture)(intptr_t)texture;
        src.mipLevel = (uint32_t)mipLevel;
        src.origin = {(uint32_t)originX, (uint32_t)originY, (uint32_t)originZ};
        WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
        dst.buffer = (WGPUBuffer)(intptr_t)buffer;
        dst.layout.offset = (uint64_t)bufferOffset;
        dst.layout.bytesPerRow = (uint32_t)bytesPerRow;
        dst.layout.rowsPerImage = (uint32_t)height;
        WGPUExtent3D extent = {(uint32_t)width, (uint32_t)height, 1};
        wgpuCommandEncoderCopyTextureToBuffer(
            (WGPUCommandEncoder)(intptr_t)encoder, &src, &dst, &extent);
    }

private:
    // Guards against unbalanced popErrorScope, which panics inside wgpu-native
    // (Rust panic → process abort — not catchable across the FFI boundary).
    std::mutex scopesMutex_;
    std::unordered_map<int64_t, int> errorScopeDepth_;
};

HybridNitroWebgpuImpl g_impl;

}  // namespace

// ── Registration (all platforms — runs when the shared library loads) ────────
#if defined(_MSC_VER)
static int _nitro_webgpu_autoregister =
    ((gImpl = &g_impl), nitro_webgpu_register_impl(&g_impl), 0);
#else
__attribute__((constructor)) static void _nitro_webgpu_autoregister() {
    gImpl = &g_impl;
    nitro_webgpu_register_impl(&g_impl);
}
#endif

// ── Presentation core (same TU: shares WgpuContext and the wgpu instance) ────
#include "present/present_core.cpp"
