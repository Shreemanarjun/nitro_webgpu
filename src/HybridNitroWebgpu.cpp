// HybridNitroWebgpu — shared C++ implementation over wgpu-native.
// The webgpu.h ABI is provided by the vendored wgpu-native static library
// (scripts/fetch_wgpu_native.sh). Quoted includes resolve relative to this
// file, so no extra include paths are needed on any platform's build.
#include "../lib/src/generated/cpp/nitro_webgpu.native.g.h"

#include "third_party/wgpu_native/include/webgpu/webgpu.h"
#include "third_party/wgpu_native/include/webgpu/wgpu.h"

#include <cstdio>
#include <mutex>
#include <stdexcept>
#include <string>

namespace {

// Curated GpuBackend bits (see GpuBackend in nitro_webgpu.native.dart) —
// mapped explicitly so the Dart API never carries raw wgpu ABI values.
WGPUInstanceBackend mapBackends(int64_t bits) {
    if (bits == 0) return WGPUInstanceBackend_All;
    WGPUInstanceBackend out = 0;
    if (bits & (1 << 0)) out |= WGPUInstanceBackend_Vulkan;
    if (bits & (1 << 1)) out |= WGPUInstanceBackend_Metal;
    if (bits & (1 << 2)) out |= WGPUInstanceBackend_DX12;
    if (bits & (1 << 3)) out |= WGPUInstanceBackend_GL;
    return out;
}

// Owns the process-wide WGPUInstance. Grows the callback pump thread in M1a.
class WgpuContext {
public:
    static WgpuContext& get() {
        static WgpuContext ctx;
        return ctx;
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
    }

    WGPUInstance instance() {
        std::lock_guard<std::mutex> lock(mutex_);
        return instance_;
    }

private:
    std::mutex mutex_;
    WGPUInstance instance_ = nullptr;
};

class HybridNitroWebgpuImpl final : public HybridNitroWebgpu {
public:
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
};

HybridNitroWebgpuImpl g_impl;

}  // namespace

// ── Registration (all platforms — runs when the shared library loads) ────────
#if defined(_MSC_VER)
static int _nitro_webgpu_autoregister =
    (nitro_webgpu_register_impl(&g_impl), 0);
#else
__attribute__((constructor)) static void _nitro_webgpu_autoregister() {
    nitro_webgpu_register_impl(&g_impl);
}
#endif
