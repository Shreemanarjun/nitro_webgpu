// Shared presentation core — pipelined presenter with a 3-slot target ring.
//
// This file is #include'd at the end of HybridNitroWebgpu.cpp so it compiles
// into the core library's single TU: it shares the process WGPUInstance and
// the WgpuContext callback pump, and adds zero build-system wiring.
//
// Ring flow (per slot: 0 = free, 1 = acquired/rendering, 2 = in flight):
//   acquire  → hand out a free slot's render-target view (round-robin)
//   (Dart renders + submits via the core module)
//   present  → GPU path: onSubmittedWorkDone → gpu sink(texture, slot);
//              the shim blits and calls frame_done(slot) → slot free.
//              Readback path: copyTextureToBuffer + mapAsync per slot →
//              pixel sink → unmap → slot free.
// With 3 slots, frame N+1 renders while frame N presents — throughput is
// bounded by the GPU pass time, not the full present round trip.

#include "present_core.h"

#ifdef __ANDROID__
#include <android/native_window.h>
#endif

namespace {

constexpr int kNwpSlots = 3;

struct NwpSlot {
    WGPUTexture target = nullptr;
    WGPUTextureView view = nullptr;
    WGPUBuffer readback = nullptr;
    // 0 = free, 1 = acquired (Dart rendering), 2 = present in flight
    std::atomic<int> state{0};
};

struct NwpPresenter {
    WGPUDevice device = nullptr;  // borrowed — the app owns the device
    WGPUQueue queue = nullptr;    // +1 ref, released on destroy
    int32_t width = 0;
    int32_t height = 0;
    int32_t pendingWidth = 0;
    int32_t pendingHeight = 0;
    int32_t alignedBytesPerRow = 0;
    NwpSlot slots[kNwpSlots];
    int nextSlot = 0;         // round-robin cursor (Dart thread only)
    int acquiredSlot = -1;    // slot handed out by acquire (Dart thread only)
    bool destroyPending = false;  // guarded by gPresentersMutex
    NwpFrameSink sink = nullptr;
    void* sinkUser = nullptr;
    NwpGpuFrameSink gpuSink = nullptr;
    void* gpuSinkUser = nullptr;

    // Surface mode (nwp_presenter_create_surface): renders straight into a
    // WGPUSurface swapchain instead of the offscreen ring.
    WGPUSurface surface = nullptr;
    void* nativeWindow = nullptr;  // owned (ANativeWindow* on Android)
    WGPUTextureFormat surfaceFormat = WGPUTextureFormat_RGBA8Unorm;
    WGPUTexture surfaceTexture = nullptr;  // current frame, between acquire/present
    WGPUTextureView surfaceView = nullptr;
    bool surfaceMode = false;
};

std::mutex gPresentersMutex;
std::unordered_map<int64_t, NwpPresenter*> gPresenters;
int64_t gNextPresenterToken = 1;

void nwpDestroySurface(NwpPresenter* p);  // defined below

NwpPresenter* nwpFind(int64_t token) {
    std::lock_guard<std::mutex> lock(gPresentersMutex);
    auto it = gPresenters.find(token);
    return it == gPresenters.end() ? nullptr : it->second;
}

void nwpReleaseTargets(NwpPresenter* p) {
    for (auto& s : p->slots) {
        if (s.view) wgpuTextureViewRelease(s.view);
        if (s.target) {
            wgpuTextureDestroy(s.target);
            wgpuTextureRelease(s.target);
        }
        if (s.readback) {
            wgpuBufferDestroy(s.readback);
            wgpuBufferRelease(s.readback);
        }
        s.view = nullptr;
        s.target = nullptr;
        s.readback = nullptr;
    }
}

// Frees the presenter. Callers must know no callback still references it.
void nwpFinalize(int64_t token, NwpPresenter* p) {
    {
        std::lock_guard<std::mutex> lock(gPresentersMutex);
        gPresenters.erase(token);
    }
    WgpuContext::get().unregisterDevice(p->device);
    if (p->surfaceMode) nwpDestroySurface(p);
    nwpReleaseTargets(p);
    wgpuQueueRelease(p->queue);
    delete p;
}

bool nwpAnyInflight(NwpPresenter* p) {
    for (auto& s : p->slots) {
        if (s.state.load() == 2) return true;
    }
    return false;
}

// Completes an in-flight present on [slot]: frees the slot, or finalizes the
// presenter when a destroy was requested and this was the last in-flight
// present. Check + transition run under gPresentersMutex so a concurrent
// destroy cannot fall through the gap.
void nwpCompleteInflight(int64_t token, NwpPresenter* p, int slot) {
    bool finalize = false;
    {
        std::lock_guard<std::mutex> lock(gPresentersMutex);
        int expected = 2;
        p->slots[slot].state.compare_exchange_strong(expected, 0);
        if (p->destroyPending && !nwpAnyInflight(p)) finalize = true;
    }
    if (finalize) nwpFinalize(token, p);
}

bool nwpCreateTargets(NwpPresenter* p, int32_t width, int32_t height) {
    nwpReleaseTargets(p);
    p->width = width;
    p->height = height;
    p->alignedBytesPerRow = ((width * 4 + 255) / 256) * 256;

    for (auto& s : p->slots) {
        WGPUTextureDescriptor td = WGPU_TEXTURE_DESCRIPTOR_INIT;
        td.label = {"nwp_target", WGPU_STRLEN};
        td.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc;
        td.dimension = WGPUTextureDimension_2D;
        td.size = {(uint32_t)width, (uint32_t)height, 1};
        td.format = WGPUTextureFormat_BGRA8Unorm;
        td.mipLevelCount = 1;
        td.sampleCount = 1;
        s.target = wgpuDeviceCreateTexture(p->device, &td);
        if (!s.target) return false;

        WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
        vd.label = {"nwp_target_view", WGPU_STRLEN};
        s.view = wgpuTextureCreateView(s.target, &vd);
        if (!s.view) return false;

        WGPUBufferDescriptor bd = WGPU_BUFFER_DESCRIPTOR_INIT;
        bd.label = {"nwp_readback", WGPU_STRLEN};
        bd.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst;
        bd.size = (uint64_t)p->alignedBytesPerRow * (uint64_t)height;
        s.readback = wgpuDeviceCreateBuffer(p->device, &bd);
        if (!s.readback) return false;
    }
    return true;
}

void nwpReleaseSurfaceFrame(NwpPresenter* p) {
    if (p->surfaceView) {
        wgpuTextureViewRelease(p->surfaceView);
        p->surfaceView = nullptr;
    }
    if (p->surfaceTexture) {
        wgpuTextureRelease(p->surfaceTexture);
        p->surfaceTexture = nullptr;
    }
}

void nwpConfigureSurface(NwpPresenter* p, int32_t width, int32_t height) {
    // Android Vulkan/GLES swapchains are RGBA8Unorm; capabilities need the
    // adapter (which the presenter doesn't hold), so configure directly.
    WGPUSurfaceConfiguration cfg = WGPU_SURFACE_CONFIGURATION_INIT;
    cfg.device = p->device;
    cfg.format = p->surfaceFormat;
    cfg.usage = WGPUTextureUsage_RenderAttachment;
    cfg.width = (uint32_t)width;
    cfg.height = (uint32_t)height;
    cfg.alphaMode = WGPUCompositeAlphaMode_Auto;
    cfg.presentMode = WGPUPresentMode_Fifo;
    wgpuSurfaceConfigure(p->surface, &cfg);
    p->width = width;
    p->height = height;
}

void nwpDestroySurface(NwpPresenter* p) {
    nwpReleaseSurfaceFrame(p);
    if (p->surface) {
        wgpuSurfaceUnconfigure(p->surface);
        wgpuSurfaceRelease(p->surface);
        p->surface = nullptr;
    }
#ifdef __ANDROID__
    if (p->nativeWindow) {
        ANativeWindow_release((ANativeWindow*)p->nativeWindow);
    }
#endif
    p->nativeWindow = nullptr;
}

// Builds a WGPUSurface for [window] and configures it at the current size.
bool nwpAttachWindow(NwpPresenter* p, void* window) {
    WGPUSurfaceSourceAndroidNativeWindow src = {};
    src.chain.sType = WGPUSType_SurfaceSourceAndroidNativeWindow;
    src.window = window;
    WGPUSurfaceDescriptor sd = WGPU_SURFACE_DESCRIPTOR_INIT;
    sd.nextInChain = &src.chain;
    WGPUSurface surface =
        wgpuInstanceCreateSurface(WgpuContext::get().instance(), &sd);
    if (!surface) return false;
    p->surface = surface;
    p->nativeWindow = window;
    nwpConfigureSurface(p, p->width, p->height);
    return true;
}

}  // namespace

extern "C" {

int64_t nwp_presenter_create(int64_t deviceAddress, int32_t width,
                             int32_t height) {
    if (!deviceAddress || width <= 0 || height <= 0) return 0;
    auto* p = new NwpPresenter();
    p->device = (WGPUDevice)(intptr_t)deviceAddress;
    p->queue = wgpuDeviceGetQueue(p->device);
    if (!p->queue || !nwpCreateTargets(p, width, height)) {
        nwpReleaseTargets(p);
        if (p->queue) wgpuQueueRelease(p->queue);
        delete p;
        return 0;
    }
    // Presenter registration keeps the pump polling this device even after
    // the app releases its own device handle (presents must still complete).
    WgpuContext::get().registerDevice(p->device);
    std::lock_guard<std::mutex> lock(gPresentersMutex);
    const int64_t token = gNextPresenterToken++;
    gPresenters[token] = p;
    return token;
}

int64_t nwp_presenter_create_surface(int64_t deviceAddress,
                                     void* nativeWindow, int32_t width,
                                     int32_t height) {
    if (!deviceAddress || !nativeWindow || width <= 0 || height <= 0) return 0;
    auto* p = new NwpPresenter();
    p->surfaceMode = true;
    p->device = (WGPUDevice)(intptr_t)deviceAddress;
    p->queue = wgpuDeviceGetQueue(p->device);
    p->width = width;
    p->height = height;
    if (!p->queue || !nwpAttachWindow(p, nativeWindow)) {
        if (p->queue) wgpuQueueRelease(p->queue);
        delete p;
        return 0;
    }
    WgpuContext::get().registerDevice(p->device);
    std::lock_guard<std::mutex> lock(gPresentersMutex);
    const int64_t token = gNextPresenterToken++;
    gPresenters[token] = p;
    return token;
}

void nwp_presenter_replace_surface(int64_t token, void* nativeWindow) {
    NwpPresenter* p = nwpFind(token);
    if (!p || !p->surfaceMode) return;
    nwpDestroySurface(p);
    if (nativeWindow) nwpAttachWindow(p, nativeWindow);
}

void nwp_presenter_set_sink(int64_t token, NwpFrameSink sink, void* user) {
    NwpPresenter* p = nwpFind(token);
    if (!p) return;
    p->sink = sink;
    p->sinkUser = user;
}

void nwp_presenter_set_gpu_sink(int64_t token, NwpGpuFrameSink sink,
                                void* user) {
    NwpPresenter* p = nwpFind(token);
    if (!p) return;
    p->gpuSink = sink;
    p->gpuSinkUser = user;
}

void nwp_presenter_frame_done(int64_t token, int32_t slot) {
    NwpPresenter* p = nwpFind(token);
    if (!p || slot < 0 || slot >= kNwpSlots) return;
    nwpCompleteInflight(token, p, slot);
}

void* nwp_presenter_metal_device(int64_t token) {
    NwpPresenter* p = nwpFind(token);
    if (!p) return nullptr;
    return wgpuDeviceGetNativeMetalDevice(p->device);
}

int64_t nwp_presenter_acquire(int64_t token) {
    NwpPresenter* p = nwpFind(token);
    if (!p || p->destroyPending) return 0;

    if (p->surfaceMode) {
        if (!p->surface) return 0;  // parked (window lost)
        if (p->surfaceView) return (int64_t)(intptr_t)p->surfaceView;
        if (p->pendingWidth > 0 &&
            (p->pendingWidth != p->width || p->pendingHeight != p->height)) {
            nwpConfigureSurface(p, p->pendingWidth, p->pendingHeight);
            p->pendingWidth = 0;
            p->pendingHeight = 0;
        }
        for (int attempt = 0; attempt < 2; attempt++) {
            WGPUSurfaceTexture st = WGPU_SURFACE_TEXTURE_INIT;
            wgpuSurfaceGetCurrentTexture(p->surface, &st);
            if (st.status == WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal ||
                st.status ==
                    WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal) {
                p->surfaceTexture = st.texture;
                WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
                vd.label = {"nwp_surface_view", WGPU_STRLEN};
                p->surfaceView = wgpuTextureCreateView(st.texture, &vd);
                if (!p->surfaceView) {
                    wgpuTextureRelease(st.texture);
                    p->surfaceTexture = nullptr;
                    return 0;
                }
                return (int64_t)(intptr_t)p->surfaceView;
            }
            if (st.texture) wgpuTextureRelease(st.texture);
            if (st.status == WGPUSurfaceGetCurrentTextureStatus_Outdated ||
                st.status == WGPUSurfaceGetCurrentTextureStatus_Timeout) {
                nwpConfigureSurface(p, p->width, p->height);
                continue;  // one retry after reconfigure
            }
            return 0;  // lost / device error
        }
        return 0;
    }

    // Backpressure: allow overlap (render N+1 while N presents) but never
    // queue more than 2 unfinished presents — without this cap, several
    // saturating views flood the GPU queue and pass latency explodes.
    int inflight = 0;
    for (auto& s : p->slots) {
        if (s.state.load() == 2) inflight++;
    }
    if (inflight >= 2) return 0;

    // Apply a pending resize only with a fully idle ring (recreating targets
    // that an in-flight present still reads would race the GPU).
    if (p->pendingWidth > 0 &&
        (p->pendingWidth != p->width || p->pendingHeight != p->height)) {
        for (auto& s : p->slots) {
            if (s.state.load() != 0) return 0;  // drain first
        }
        if (!nwpCreateTargets(p, p->pendingWidth, p->pendingHeight)) return 0;
        p->pendingWidth = 0;
        p->pendingHeight = 0;
    }

    for (int i = 0; i < kNwpSlots; i++) {
        const int slot = (p->nextSlot + i) % kNwpSlots;
        int expected = 0;
        if (p->slots[slot].state.compare_exchange_strong(expected, 1)) {
            p->acquiredSlot = slot;
            p->nextSlot = (slot + 1) % kNwpSlots;
            return (int64_t)(intptr_t)p->slots[slot].view;
        }
    }
    return 0;  // every slot busy — drop this frame
}

void nwp_presenter_present(int64_t token) {
    NwpPresenter* p = nwpFind(token);
    if (!p) return;

    if (p->surfaceMode) {
        if (!p->surface || !p->surfaceView) return;
        wgpuSurfacePresent(p->surface);
        nwpReleaseSurfaceFrame(p);
        return;
    }

    const int slot = p->acquiredSlot;
    if (slot < 0 || slot >= kNwpSlots) return;
    int expected = 1;
    if (!p->slots[slot].state.compare_exchange_strong(expected, 2)) return;
    p->acquiredSlot = -1;

    if (p->gpuSink) {
        // GPU path: once the app's submitted work completes, hand the slot's
        // native texture to the shim, which blits it and calls
        // nwp_presenter_frame_done(slot).
        struct GpuPresentOp {
            NwpPresenter* p;
            int64_t token;
            int slot;
        };
        auto* op = new GpuPresentOp{p, token, slot};
        WGPUQueueWorkDoneCallbackInfo wcb = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
        wcb.mode = WGPUCallbackMode_AllowProcessEvents;
        wcb.userdata1 = op;
        wcb.callback = [](WGPUQueueWorkDoneStatus status, WGPUStringView,
                          void* ud1, void*) {
            auto* op = static_cast<GpuPresentOp*>(ud1);
            NwpPresenter* p = op->p;
            void* mtl = nullptr;
            if (status == WGPUQueueWorkDoneStatus_Success && p->gpuSink) {
                mtl = wgpuTextureGetNativeMetalTexture(p->slots[op->slot].target);
            }
            if (mtl) {
                p->gpuSink(op->token, p->width, p->height, mtl, op->slot,
                           p->gpuSinkUser);
            } else {
                // Failed frame: release the slot for the next acquire.
                nwpCompleteInflight(op->token, p, op->slot);
            }
            WgpuContext::get().opFinished();
            delete op;
        };
        wgpuQueueOnSubmittedWorkDone(p->queue, wcb);
        WgpuContext::get().opStarted();
        return;
    }

    // Readback path.
    NwpSlot& s = p->slots[slot];
    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(p->device, &ed);
    WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
    src.texture = s.target;
    WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
    dst.buffer = s.readback;
    dst.layout.offset = 0;
    dst.layout.bytesPerRow = (uint32_t)p->alignedBytesPerRow;
    dst.layout.rowsPerImage = (uint32_t)p->height;
    WGPUExtent3D extent = {(uint32_t)p->width, (uint32_t)p->height, 1};
    wgpuCommandEncoderCopyTextureToBuffer(encoder, &src, &dst, &extent);
    WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(encoder, nullptr);
    wgpuQueueSubmit(p->queue, 1, &cmd);
    wgpuCommandBufferRelease(cmd);
    wgpuCommandEncoderRelease(encoder);

    struct MapPresentOp {
        NwpPresenter* p;
        int64_t token;
        int slot;
    };
    auto* op = new MapPresentOp{p, token, slot};
    const size_t mapSize = (size_t)p->alignedBytesPerRow * (size_t)p->height;
    WGPUBufferMapCallbackInfo cb = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    cb.mode = WGPUCallbackMode_AllowProcessEvents;
    cb.userdata1 = op;
    cb.callback = [](WGPUMapAsyncStatus status, WGPUStringView, void* ud1,
                     void*) {
        auto* op = static_cast<MapPresentOp*>(ud1);
        NwpPresenter* p = op->p;
        NwpSlot& s = p->slots[op->slot];
        if (status == WGPUMapAsyncStatus_Success) {
            const size_t n = (size_t)p->alignedBytesPerRow * (size_t)p->height;
            const void* mapped = wgpuBufferGetConstMappedRange(s.readback, 0, n);
            if (mapped && p->sink) {
                p->sink(op->token, (const uint8_t*)mapped, p->width, p->height,
                        p->alignedBytesPerRow, p->sinkUser);
            }
            wgpuBufferUnmap(s.readback);
        }
        nwpCompleteInflight(op->token, p, op->slot);
        WgpuContext::get().opFinished();
        delete op;
    };
    wgpuBufferMapAsync(s.readback, WGPUMapMode_Read, 0, mapSize, cb);
    WgpuContext::get().opStarted();
}

int32_t nwp_presenter_format(int64_t token) {
    NwpPresenter* p = nwpFind(token);
    if (p && p->surfaceMode) return (int32_t)p->surfaceFormat;
    return (int32_t)WGPUTextureFormat_BGRA8Unorm;
}

void nwp_presenter_resize(int64_t token, int32_t width, int32_t height) {
    NwpPresenter* p = nwpFind(token);
    if (!p || width <= 0 || height <= 0) return;
    p->pendingWidth = width;
    p->pendingHeight = height;
}

int32_t nwp_presenter_is_busy(int64_t token) {
    NwpPresenter* p = nwpFind(token);
    return (p && nwpAnyInflight(p)) ? 1 : 0;
}

void nwp_presenter_destroy(int64_t token) {
    NwpPresenter* p = nullptr;
    bool busy = false;
    {
        std::lock_guard<std::mutex> lock(gPresentersMutex);
        auto it = gPresenters.find(token);
        if (it == gPresenters.end()) return;
        p = it->second;
        if (p->destroyPending) return;  // already tearing down
        p->destroyPending = true;
        busy = nwpAnyInflight(p);
    }
    // Presents still in flight: the last completion (map callback, workdone
    // failure path, or frame_done) finalizes the presenter — never freeing
    // memory a pending callback might still touch.
    if (!busy) nwpFinalize(token, p);
}

}  // extern "C"
