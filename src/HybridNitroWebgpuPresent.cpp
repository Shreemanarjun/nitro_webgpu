// HybridNitroWebgpuPresent — NativeImpl.cpp implementation (Windows/Linux).
//
// M2.4/M2.5: CPU-readback presenter. Frame state and the wgpu readback ring
// live in the core nitro_webgpu library (src/present/present_core.cpp,
// exported as the nwp_* C ABI); the platform plugin
// (windows/nitro_webgpu_plugin.cpp, linux/nitro_webgpu_plugin.cc) owns the
// Flutter texture objects and installs an NwpTextureOps table at engine
// startup. This file bridges the two — it compiles into the
// nitro_webgpu_present library, which stays Flutter- and wgpu-free.
#include "../lib/src/generated/cpp/nitro_webgpu_present.native.g.h"

#include "native/dart_api_dl.h"
#include "present/nwp_texture_ops.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <thread>
#include <unordered_map>

// nwp_* C ABI exported by the core nitro_webgpu library. Declared plainly —
// including present_core.h would stamp NWP_EXPORT (dllexport) on symbols
// this module *imports* on Windows.
extern "C" {
typedef void (*NwpFrameSink)(int64_t token, const uint8_t* pixels,
                             int32_t width, int32_t height,
                             int32_t bytesPerRow, void* user);
int64_t nwp_presenter_create(int64_t deviceAddress, int32_t width,
                             int32_t height);
void nwp_presenter_set_sink(int64_t token, NwpFrameSink sink, void* user);
int64_t nwp_presenter_acquire(int64_t token);
void nwp_presenter_present(int64_t token);
int32_t nwp_presenter_format(int64_t token);
void nwp_presenter_resize(int64_t token, int32_t width, int32_t height);
int32_t nwp_presenter_is_busy(int64_t token);
void nwp_presenter_destroy(int64_t token);
}

namespace {

// ── Texture ops installed by the platform plugin ────────────────────────

std::mutex gOpsMutex;
NwpTextureOps gOps{};
bool gOpsInstalled = false;

NwpTextureOps copyOps() {
    std::lock_guard<std::mutex> lock(gOpsMutex);
    return gOps;
}

// ── Per-presenter platform state ─────────────────────────────────────────

struct PresentEntry {
    int64_t textureId = 0;
    void* handle = nullptr;  // plugin-owned texture object
};

std::mutex gEntriesMutex;
std::unordered_map<int64_t, PresentEntry*> gEntries;

PresentEntry* findEntry(int64_t token) {
    std::lock_guard<std::mutex> lock(gEntriesMutex);
    auto it = gEntries.find(token);
    return it == gEntries.end() ? nullptr : it->second;
}

// ── Dart-port completion helpers ─────────────────────────────────────────

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

// Readback sink — runs on a wgpu callback thread while the readback buffer
// is mapped. The plugin copies the rows synchronously and signals Flutter.
void frameSink(int64_t /*token*/, const uint8_t* pixels, int32_t width,
               int32_t height, int32_t bytesPerRow, void* user) {
    auto* entry = static_cast<PresentEntry*>(user);
    const NwpTextureOps ops = copyOps();
    if (ops.publish_frame && entry->handle) {
        ops.publish_frame(ops.ctx, entry->handle, pixels, width, height,
                          bytesPerRow);
    }
}

}  // namespace

extern "C" void nwp_set_texture_ops(const NwpTextureOps* ops) {
    std::lock_guard<std::mutex> lock(gOpsMutex);
    if (ops) {
        gOps = *ops;
        gOpsInstalled = true;
    } else {
        gOps = NwpTextureOps{};
        gOpsInstalled = false;
    }
}

class HybridNitroWebgpuPresentImpl final : public HybridNitroWebgpuPresent {
public:
    int64_t createPresenter(int64_t deviceAddress, int64_t widthPx,
                            int64_t heightPx) override {
        NwpTextureOps ops;
        {
            std::lock_guard<std::mutex> lock(gOpsMutex);
            if (!gOpsInstalled) {
                static std::atomic<bool> warned{false};
                if (!warned.exchange(true)) {
                    std::fprintf(
                        stderr,
                        "nitro_webgpu: presentation plugin is not registered "
                        "— WebGpuView stays blank (missing pluginClass "
                        "registration?)\n");
                }
                return 0;
            }
            ops = gOps;
        }
        const int64_t token = nwp_presenter_create(
            deviceAddress, (int32_t)widthPx, (int32_t)heightPx);
        if (token == 0) return 0;
        auto* entry = new PresentEntry();
        entry->textureId = ops.register_texture(ops.ctx, &entry->handle);
        {
            std::lock_guard<std::mutex> lock(gEntriesMutex);
            gEntries[token] = entry;
        }
        nwp_presenter_set_sink(token, &frameSink, entry);
        return token;
    }

    int64_t flutterTextureId(int64_t token) override {
        PresentEntry* entry = findEntry(token);
        return entry ? entry->textureId : 0;
    }

    void acquireFrame(int64_t token, NitroError* /*_nitro_err*/,
                      int64_t dartPort) override {
        postInt64(dartPort, nwp_presenter_acquire(token));
    }

    int64_t acquireFrameSync(int64_t token) override {
        // Lock-free ring acquire — safe on the calling (Dart) thread.
        return nwp_presenter_acquire(token);
    }

    void presentFrame(int64_t token) override {
        nwp_presenter_present(token);
    }

    int64_t presenterFormat(int64_t token) override {
        return (int64_t)nwp_presenter_format(token);
    }

    bool presenterUsesGpuPath(int64_t /*token*/) override {
        // Phase A: CPU readback everywhere on desktop Windows/Linux.
        return false;
    }

    void presenterSetSurfaceSize(int64_t, int64_t, int64_t) override {
        // Ring presenters render offscreen — no window surface to resize;
        // the render size (resizePresenter) is the only dimension.
    }

    double requestMaxRefreshRate() override {
        // Desktop compositors manage refresh themselves.
        return 0.0;
    }

    void resizePresenter(int64_t token, int64_t widthPx,
                         int64_t heightPx) override {
        nwp_presenter_resize(token, (int32_t)widthPx, (int32_t)heightPx);
    }

    void destroyPresenter(int64_t token, NitroError* /*_nitro_err*/,
                          int64_t dartPort) override {
        // Drain the in-flight present before unregistering the texture
        // (bounded; the core defers its own teardown safely if still busy).
        std::thread([token, dartPort]() {
            for (int i = 0; i < 500 && nwp_presenter_is_busy(token) == 1;
                 i++) {
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            nwp_presenter_destroy(token);
            PresentEntry* entry = nullptr;
            {
                std::lock_guard<std::mutex> lock(gEntriesMutex);
                auto it = gEntries.find(token);
                if (it != gEntries.end()) {
                    entry = it->second;
                    gEntries.erase(it);
                }
            }
            if (entry) {
                const NwpTextureOps ops = copyOps();
                if (ops.unregister_texture && entry->handle) {
                    ops.unregister_texture(ops.ctx, entry->handle);
                }
                delete entry;
            }
            postNull(dartPort);
        }).detach();
    }
};

static HybridNitroWebgpuPresentImpl g_impl;

// Auto-register on shared library load — no manual init call needed.
#if defined(_WIN32) || (defined(__linux__) && !defined(__ANDROID__))
#if defined(_WIN32)
namespace {
  struct _AutoRegister {
    _AutoRegister() { nitro_webgpu_present_register_impl(&g_impl); }
  };
  _AutoRegister _auto_register_instance;
}
#else
__attribute__((constructor))
static void nitro_webgpu_present_auto_register() {
    nitro_webgpu_present_register_impl(&g_impl);
}
#endif
#endif // auto-register on C++ platforms
