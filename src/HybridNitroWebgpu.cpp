// HybridNitroWebgpu — shared C++ implementation over wgpu-native.
// The webgpu.h ABI is provided by the vendored wgpu-native static library
// (scripts/fetch_wgpu_native.sh). Quoted includes resolve relative to this
// file, so no extra include paths are needed on any platform's build.
#include "../lib/src/generated/cpp/nitro_webgpu.native.g.h"

#include "native/dart_api_dl.h"
#include "third_party/wgpu_native/include/webgpu/webgpu.h"
#include "third_party/wgpu_native/include/webgpu/wgpu.h"

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
        out.maxTextureDimension1D = limits.maxTextureDimension1D;
        out.maxTextureDimension2D = limits.maxTextureDimension2D;
        out.maxTextureDimension3D = limits.maxTextureDimension3D;
        out.maxTextureArrayLayers = limits.maxTextureArrayLayers;
        out.maxBindGroups = limits.maxBindGroups;
        out.maxBindingsPerBindGroup = limits.maxBindingsPerBindGroup;
        out.maxUniformBufferBindingSize = (int64_t)limits.maxUniformBufferBindingSize;
        out.maxStorageBufferBindingSize = (int64_t)limits.maxStorageBufferBindingSize;
        out.minUniformBufferOffsetAlignment = limits.minUniformBufferOffsetAlignment;
        out.minStorageBufferOffsetAlignment = limits.minStorageBufferOffsetAlignment;
        out.maxBufferSize = (int64_t)limits.maxBufferSize;
        out.maxComputeWorkgroupStorageSize = limits.maxComputeWorkgroupStorageSize;
        out.maxComputeInvocationsPerWorkgroup = limits.maxComputeInvocationsPerWorkgroup;
        out.maxComputeWorkgroupSizeX = limits.maxComputeWorkgroupSizeX;
        out.maxComputeWorkgroupSizeY = limits.maxComputeWorkgroupSizeY;
        out.maxComputeWorkgroupSizeZ = limits.maxComputeWorkgroupSizeZ;
        return out.toNativeBuffer();
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

        static const WGPUFeatureName kTimestampFeature[] = {
            WGPUFeatureName_TimestampQuery};
        if (desc.requireTimestampQueries) {
            wgpuDesc.requiredFeatureCount = 1;
            wgpuDesc.requiredFeatures = kTimestampFeature;
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
        };
        auto* dop = new DeviceOp{{_nitro_err, dartPort}, label};

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
        wd.dimension = WGPUTextureDimension_2D;
        wd.size = {(uint32_t)d.width, (uint32_t)d.height, 1};
        wd.format = (WGPUTextureFormat)d.format;
        wd.mipLevelCount = (uint32_t)d.mipLevelCount;
        wd.sampleCount = (uint32_t)d.sampleCount;
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

    int64_t textureCreateView(int64_t texture, const std::string& label) override {
        WGPUTextureViewDescriptor wd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
        wd.label = toView(label);
        WGPUTextureView view =
            wgpuTextureCreateView((WGPUTexture)(intptr_t)texture, &wd);
        if (!view) throw std::runtime_error("wgpuTextureCreateView failed");
        return (int64_t)(intptr_t)view;
    }

    void textureViewRelease(int64_t view) override {
        wgpuTextureViewRelease((WGPUTextureView)(intptr_t)view);
    }

    void queueWriteTexture(int64_t queue, int64_t texture, const uint8_t* data,
                           size_t data_length, int64_t bytesPerRow,
                           int64_t width, int64_t height) override {
        WGPUTexelCopyTextureInfo dst = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
        dst.texture = (WGPUTexture)(intptr_t)texture;
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

        WGPUFragmentState fragment = WGPU_FRAGMENT_STATE_INIT;
        fragment.module = (WGPUShaderModule)(intptr_t)d.moduleAddress;
        fragment.entryPoint = toView(d.fragmentEntryPoint);
        fragment.targetCount = 1;
        fragment.targets = &target;

        WGPURenderPipelineDescriptor wd = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        wd.vertex.module = (WGPUShaderModule)(intptr_t)d.moduleAddress;
        wd.vertex.entryPoint = toView(d.vertexEntryPoint);
        wd.primitive.topology = (WGPUPrimitiveTopology)d.topology;
        wd.fragment = &fragment;

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
        }
        WGPURenderPassDescriptor wd = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
        wd.label = toView(d.label);
        wd.colorAttachmentCount = attachments.size();
        wd.colorAttachments = attachments.data();
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
                                    int64_t width, int64_t height) override {
        WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
        src.texture = (WGPUTexture)(intptr_t)texture;
        WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
        dst.buffer = (WGPUBuffer)(intptr_t)buffer;
        dst.layout.offset = 0;
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
