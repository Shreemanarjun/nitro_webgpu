// Shared presentation core — CPU-readback presenter (M2.0).
//
// This file is #include'd at the end of HybridNitroWebgpu.cpp so it compiles
// into the core library's single TU: it shares the process WGPUInstance and
// the WgpuContext callback pump, and adds zero build-system wiring.
//
// Flow per frame:
//   acquire  → hand out the render-target view (state: idle → acquired)
//   (Dart renders + submits via the core module)
//   present  → encode copyTextureToBuffer, submit, mapAsync (state → inflight)
//   map done → sink(pixels) on the pump thread, unmap (state → idle)

#include "present_core.h"

namespace {

struct NwpPresenter {
    WGPUDevice device = nullptr;  // borrowed — the app owns the device
    WGPUQueue queue = nullptr;    // +1 ref, released on destroy
    int32_t width = 0;
    int32_t height = 0;
    int32_t pendingWidth = 0;
    int32_t pendingHeight = 0;
    WGPUTexture target = nullptr;
    WGPUTextureView view = nullptr;
    WGPUBuffer readback = nullptr;
    int32_t alignedBytesPerRow = 0;
    // 0 = idle, 1 = acquired (Dart rendering), 2 = readback in flight
    std::atomic<int> state{0};
    NwpFrameSink sink = nullptr;
    void* sinkUser = nullptr;
};

std::mutex gPresentersMutex;
std::unordered_map<int64_t, NwpPresenter*> gPresenters;
int64_t gNextPresenterToken = 1;

NwpPresenter* nwpFind(int64_t token) {
    std::lock_guard<std::mutex> lock(gPresentersMutex);
    auto it = gPresenters.find(token);
    return it == gPresenters.end() ? nullptr : it->second;
}

void nwpReleaseTargets(NwpPresenter* p) {
    if (p->view) wgpuTextureViewRelease(p->view);
    if (p->target) {
        wgpuTextureDestroy(p->target);
        wgpuTextureRelease(p->target);
    }
    if (p->readback) {
        wgpuBufferDestroy(p->readback);
        wgpuBufferRelease(p->readback);
    }
    p->view = nullptr;
    p->target = nullptr;
    p->readback = nullptr;
}

bool nwpCreateTargets(NwpPresenter* p, int32_t width, int32_t height) {
    nwpReleaseTargets(p);
    p->width = width;
    p->height = height;
    p->alignedBytesPerRow = ((width * 4 + 255) / 256) * 256;

    WGPUTextureDescriptor td = WGPU_TEXTURE_DESCRIPTOR_INIT;
    td.label = {"nwp_target", WGPU_STRLEN};
    td.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc;
    td.dimension = WGPUTextureDimension_2D;
    td.size = {(uint32_t)width, (uint32_t)height, 1};
    td.format = WGPUTextureFormat_BGRA8Unorm;
    td.mipLevelCount = 1;
    td.sampleCount = 1;
    p->target = wgpuDeviceCreateTexture(p->device, &td);
    if (!p->target) return false;

    WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
    vd.label = {"nwp_target_view", WGPU_STRLEN};
    p->view = wgpuTextureCreateView(p->target, &vd);
    if (!p->view) return false;

    WGPUBufferDescriptor bd = WGPU_BUFFER_DESCRIPTOR_INIT;
    bd.label = {"nwp_readback", WGPU_STRLEN};
    bd.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst;
    bd.size = (uint64_t)p->alignedBytesPerRow * (uint64_t)height;
    p->readback = wgpuDeviceCreateBuffer(p->device, &bd);
    return p->readback != nullptr;
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
    // the app releases its own device handle (readbacks must still complete).
    WgpuContext::get().registerDevice(p->device);
    std::lock_guard<std::mutex> lock(gPresentersMutex);
    const int64_t token = gNextPresenterToken++;
    gPresenters[token] = p;
    return token;
}

void nwp_presenter_set_sink(int64_t token, NwpFrameSink sink, void* user) {
    NwpPresenter* p = nwpFind(token);
    if (!p) return;
    p->sink = sink;
    p->sinkUser = user;
}

int64_t nwp_presenter_acquire(int64_t token) {
    NwpPresenter* p = nwpFind(token);
    if (!p) return 0;
    int expected = 0;
    if (!p->state.compare_exchange_strong(expected, 1)) return 0;
    if (p->pendingWidth > 0 &&
        (p->pendingWidth != p->width || p->pendingHeight != p->height)) {
        if (!nwpCreateTargets(p, p->pendingWidth, p->pendingHeight)) {
            p->state.store(0);
            return 0;
        }
    }
    p->pendingWidth = 0;
    p->pendingHeight = 0;
    return (int64_t)(intptr_t)p->view;
}

void nwp_presenter_present(int64_t token) {
    NwpPresenter* p = nwpFind(token);
    if (!p) return;
    int expected = 1;
    if (!p->state.compare_exchange_strong(expected, 2)) return;

    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(p->device, &ed);
    WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
    src.texture = p->target;
    WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
    dst.buffer = p->readback;
    dst.layout.offset = 0;
    dst.layout.bytesPerRow = (uint32_t)p->alignedBytesPerRow;
    dst.layout.rowsPerImage = (uint32_t)p->height;
    WGPUExtent3D extent = {(uint32_t)p->width, (uint32_t)p->height, 1};
    wgpuCommandEncoderCopyTextureToBuffer(encoder, &src, &dst, &extent);
    WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(encoder, nullptr);
    wgpuQueueSubmit(p->queue, 1, &cmd);
    wgpuCommandBufferRelease(cmd);
    wgpuCommandEncoderRelease(encoder);

    const size_t mapSize = (size_t)p->alignedBytesPerRow * (size_t)p->height;
    WGPUBufferMapCallbackInfo cb = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    cb.mode = WGPUCallbackMode_AllowProcessEvents;
    cb.userdata1 = p;
    cb.userdata2 = (void*)(intptr_t)token;
    cb.callback = [](WGPUMapAsyncStatus status, WGPUStringView, void* ud1,
                     void* ud2) {
        auto* p = static_cast<NwpPresenter*>(ud1);
        const int64_t token = (int64_t)(intptr_t)ud2;
        if (status == WGPUMapAsyncStatus_Success) {
            const size_t n = (size_t)p->alignedBytesPerRow * (size_t)p->height;
            const void* mapped = wgpuBufferGetConstMappedRange(p->readback, 0, n);
            if (mapped && p->sink) {
                p->sink(token, (const uint8_t*)mapped, p->width, p->height,
                        p->alignedBytesPerRow, p->sinkUser);
            }
            wgpuBufferUnmap(p->readback);
        }
        p->state.store(0);
        WgpuContext::get().opFinished();
    };
    wgpuBufferMapAsync(p->readback, WGPUMapMode_Read, 0, mapSize, cb);
    WgpuContext::get().opStarted();
}

int32_t nwp_presenter_format(int64_t token) {
    (void)token;
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
    return (p && p->state.load() == 2) ? 1 : 0;
}

void nwp_presenter_destroy(int64_t token) {
    NwpPresenter* p = nullptr;
    {
        std::lock_guard<std::mutex> lock(gPresentersMutex);
        auto it = gPresenters.find(token);
        if (it == gPresenters.end()) return;
        p = it->second;
        gPresenters.erase(it);
    }
    WgpuContext::get().unregisterDevice(p->device);
    nwpReleaseTargets(p);
    wgpuQueueRelease(p->queue);
    delete p;
}

}  // extern "C"
