// HybridNitroWebgpuPresent — NativeImpl.cpp implementation (Windows/Linux).
//
// M2.0 STUB: desktop Linux/Windows presentation lands in M2.4/M2.5 (they
// need a real plugin class for texture-registrar access, plus this impl
// calling the exported nwp_* API in the core nitro_webgpu library).
#include "../lib/src/generated/cpp/nitro_webgpu_present.native.g.h"

#include "native/dart_api_dl.h"

#include <cstring>
#include <stdexcept>
#include <string>

namespace {

void presentFillError(NitroError* err, const char* message) {
    if (!err) return;
    err->hasError = 1;
    err->name = strdup("UnsupportedError");
    err->message = strdup(message);
    err->code = nullptr;
    err->stackTrace = nullptr;
}

void presentPostNull(int64_t dartPort) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kNull;
    Dart_PostCObject_DL(dartPort, &obj);
}

constexpr const char* kNotSupported =
    "WebGPU presentation is not implemented on this platform yet "
    "(M2.4 Windows / M2.5 Linux)";

}  // namespace

class HybridNitroWebgpuPresentImpl final : public HybridNitroWebgpuPresent {
public:
    int64_t createPresenter(int64_t, int64_t, int64_t) override {
        throw std::runtime_error(kNotSupported);
    }

    int64_t flutterTextureId(int64_t) override {
        throw std::runtime_error(kNotSupported);
    }

    void acquireFrame(int64_t, NitroError* _nitro_err, int64_t dartPort) override {
        presentFillError(_nitro_err, kNotSupported);
        presentPostNull(dartPort);
    }

    void presentFrame(int64_t) override {
        throw std::runtime_error(kNotSupported);
    }

    int64_t presenterFormat(int64_t) override {
        throw std::runtime_error(kNotSupported);
    }

    bool presenterUsesGpuPath(int64_t) override {
        throw std::runtime_error(kNotSupported);
    }

    void presenterSetSurfaceSize(int64_t, int64_t, int64_t) override {}

    double requestMaxRefreshRate() override { return 0.0; }

    void resizePresenter(int64_t, int64_t, int64_t) override {
        throw std::runtime_error(kNotSupported);
    }

    void destroyPresenter(int64_t, NitroError* _nitro_err, int64_t dartPort) override {
        presentFillError(_nitro_err, kNotSupported);
        presentPostNull(dartPort);
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
