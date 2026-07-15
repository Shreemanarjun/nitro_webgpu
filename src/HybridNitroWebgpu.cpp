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

    void registerDevice(WGPUDevice device) {
        std::lock_guard<std::mutex> lock(devicesMutex_);
        devices_.insert(device);
        cv_.notify_one();
    }

    // Removes the device from the pump sweep and releases it under the same
    // lock, so the pump can never poll a released handle.
    void unregisterAndRelease(WGPUDevice device) {
        {
            std::lock_guard<std::mutex> lock(devicesMutex_);
            devices_.erase(device);
            wgpuDeviceRelease(device);
        }
        // The device-lost event is delivered through the instance event queue;
        // keep pumping briefly so it reaches Dart even though the device is
        // gone from the poll sweep.
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
                for (WGPUDevice d : devices_) {
                    wgpuDevicePoll(d, /*wait=*/0, nullptr);
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
    std::unordered_set<WGPUDevice> devices_;
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
