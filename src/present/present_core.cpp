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
#include <android/log.h>
#include <android/native_window.h>
#endif

namespace {

constexpr int kNwpSlots = 3;

// Ring render-target format must match what the platform texture consumes:
// Apple CVPixelBuffers are BGRA; Flutter's Windows (FlutterDesktopPixelBuffer)
// and Linux (FlPixelBufferTexture) pixel-buffer textures are RGBA.
#if defined(_WIN32) || (defined(__linux__) && !defined(__ANDROID__))
constexpr WGPUTextureFormat kNwpRingFormat = WGPUTextureFormat_RGBA8Unorm;
#else
constexpr WGPUTextureFormat kNwpRingFormat = WGPUTextureFormat_BGRA8Unorm;
#endif

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
    // Per-presenter ring format: kNwpRingFormat everywhere except the
    // Android GL-fallback presenter, whose ANativeWindow buffers are RGBA.
    WGPUTextureFormat ringFormat = kNwpRingFormat;
#ifdef __ANDROID__
    // GL-backend fallback (no Vulkan on the device): wgpu's GL backend
    // cannot create an EGL swapchain on the Flutter SurfaceProducer window
    // (and wgpu-native panics trying), so frames render into the offscreen
    // ring — exactly like the desktop presenters — and each mapped frame is
    // CPU-blitted into the window with ANativeWindow_lock/unlockAndPost (a
    // CPU BufferQueue connection, which the window does accept).
    // nativeWindow + geometry are guarded by surfaceMutex in this mode.
    bool androidReadback = false;
    int32_t geomWidth = 0;
    int32_t geomHeight = 0;
    bool lockFailLogged = false;
#endif

    // Surface mode (nwp_presenter_create_surface): renders straight into a
    // WGPUSurface swapchain instead of the offscreen ring. width/height stay
    // the RENDER resolution; the swapchain itself is surfaceWidth/Height.
    // When they differ, frames render into an internal target and are
    // blit-upscaled into the swapchain at present — so render-resolution
    // changes (dynamic resolution scaling) never recreate the swapchain.
    WGPUSurface surface = nullptr;
    void* nativeWindow = nullptr;  // owned (ANativeWindow* on Android)
    WGPUTextureFormat surfaceFormat = WGPUTextureFormat_RGBA8Unorm;
    WGPUTexture surfaceTexture = nullptr;  // current frame, between acquire/present
    WGPUTextureView surfaceView = nullptr;
    bool surfaceMode = false;
    int32_t surfaceWidth = 0;
    int32_t surfaceHeight = 0;
    // Surface-mode state is touched from the Dart thread (acquire/present)
    // AND nitro's async pool (destroy/replace) — serialize those ops.
    std::mutex surfaceMutex;
    // Live public-API calls holding this presenter; destroy defers while > 0
    // so a concurrent call can never touch a freed presenter.
    std::atomic<int> opRefs{0};
    // Scaled offscreen render target (surface mode, render != surface size).
    WGPUTexture offTex = nullptr;
    WGPUTextureView offView = nullptr;
    bool offscreenAcquired = false;
#if defined(NITRO_WEBGPU_BACKEND_DAWN) && (defined(__APPLE__) || defined(_WIN32))
    // Texture-import path (Dawn): per-IOSurface import cache. Guarded by
    // the presenter's single-threaded present flow (Dart thread).
    NwpImportAcquire ioAcquire = nullptr;
    NwpImportPresented ioPresented = nullptr;
    void* ioUser = nullptr;
    struct NwpImportedSurface {
        WGPUSharedTextureMemory mem = nullptr;
        WGPUTexture tex = nullptr;
        int32_t width = 0;
        int32_t height = 0;
    };
    std::unordered_map<void*, NwpImportedSurface> ioImports;
#endif
    // Lazily-built upscale blit (fullscreen sampled triangle).
    WGPUShaderModule blitModule = nullptr;
    WGPURenderPipeline blitPipeline = nullptr;
    WGPUSampler blitSampler = nullptr;
    WGPUBindGroup blitBind = nullptr;  // rebuilt when offView changes
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

void nwpFinalize(int64_t token, NwpPresenter* p);
bool nwpAnyInflight(NwpPresenter* p);

// Public-API entry: resolves the token AND takes an operation reference so
// a concurrent destroy cannot free the presenter mid-call. Pair with the
// guard below on every exit path.
NwpPresenter* nwpFindAndRef(int64_t token) {
    std::lock_guard<std::mutex> lock(gPresentersMutex);
    auto it = gPresenters.find(token);
    if (it == gPresenters.end() || it->second->destroyPending) return nullptr;
    it->second->opRefs.fetch_add(1, std::memory_order_acq_rel);
    return it->second;
}

void nwpUnrefOp(int64_t token, NwpPresenter* p) {
    bool finalize = false;
    {
        std::lock_guard<std::mutex> lock(gPresentersMutex);
        const int prev = p->opRefs.fetch_sub(1, std::memory_order_acq_rel);
        if (prev == 1 && p->destroyPending && !nwpAnyInflight(p)) {
            finalize = true;
        }
    }
    if (finalize) nwpFinalize(token, p);
}

struct NwpOpGuard {
    int64_t token;
    NwpPresenter* p;
    ~NwpOpGuard() {
        if (p) nwpUnrefOp(token, p);
    }
};

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
#if defined(NITRO_WEBGPU_BACKEND_DAWN) && (defined(__APPLE__) || defined(_WIN32))
    for (auto& [surface, imp] : p->ioImports) {
        if (imp.tex) wgpuTextureRelease(imp.tex);
        if (imp.mem) wgpuSharedTextureMemoryRelease(imp.mem);
    }
    p->ioImports.clear();
#endif
    if (p->surfaceMode) {
        std::lock_guard<std::mutex> surfLock(p->surfaceMutex);
        nwpDestroySurface(p);
    }
#ifdef __ANDROID__
    if (p->androidReadback) {
        std::lock_guard<std::mutex> surfLock(p->surfaceMutex);
        if (p->nativeWindow) {
            ANativeWindow_release((ANativeWindow*)p->nativeWindow);
            p->nativeWindow = nullptr;
        }
    }
#endif
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
        if (p->destroyPending && !nwpAnyInflight(p) &&
            p->opRefs.load(std::memory_order_acquire) == 0) {
            finalize = true;
        }
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
        td.format = p->ringFormat;
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

void nwpReleaseOffscreen(NwpPresenter* p) {
    if (p->blitBind) {
        wgpuBindGroupRelease(p->blitBind);
        p->blitBind = nullptr;
    }
    if (p->offView) {
        wgpuTextureViewRelease(p->offView);
        p->offView = nullptr;
    }
    if (p->offTex) {
        wgpuTextureDestroy(p->offTex);
        wgpuTextureRelease(p->offTex);
        p->offTex = nullptr;
    }
}

void nwpReleaseBlit(NwpPresenter* p) {
    nwpReleaseOffscreen(p);
    if (p->blitPipeline) {
        wgpuRenderPipelineRelease(p->blitPipeline);
        p->blitPipeline = nullptr;
    }
    if (p->blitSampler) {
        wgpuSamplerRelease(p->blitSampler);
        p->blitSampler = nullptr;
    }
    if (p->blitModule) {
        wgpuShaderModuleRelease(p->blitModule);
        p->blitModule = nullptr;
    }
}

// Ensures the scaled offscreen target exists at the render size and the blit
// pipeline + bind group are ready. Returns the target view or null.
WGPUTextureView nwpEnsureOffscreen(NwpPresenter* p) {
    if (p->offTex) return p->offView;

    WGPUTextureDescriptor td = WGPU_TEXTURE_DESCRIPTOR_INIT;
    td.label = {"nwp_scaled_target", WGPU_STRLEN};
    td.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_TextureBinding;
    td.dimension = WGPUTextureDimension_2D;
    td.size = {(uint32_t)p->width, (uint32_t)p->height, 1};
    td.format = p->surfaceFormat;
    td.mipLevelCount = 1;
    td.sampleCount = 1;
    p->offTex = wgpuDeviceCreateTexture(p->device, &td);
    if (!p->offTex) return nullptr;
    WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
    p->offView = wgpuTextureCreateView(p->offTex, &vd);
    if (!p->offView) return nullptr;

    if (!p->blitPipeline) {
        static const char* kBlitWgsl =
            "struct VOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f }\n"
            "@vertex fn vs_main(@builtin(vertex_index) i: u32) -> VOut {\n"
            "  var p = array<vec2f, 3>(\n"
            "      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));\n"
            "  var o: VOut;\n"
            "  o.pos = vec4f(p[i], 0.0, 1.0);\n"
            "  o.uv = vec2f((p[i].x + 1.0) * 0.5, 1.0 - (p[i].y + 1.0) * 0.5);\n"
            "  return o;\n"
            "}\n"
            "@group(0) @binding(0) var s: sampler;\n"
            "@group(0) @binding(1) var t: texture_2d<f32>;\n"
            "@fragment fn fs_main(v: VOut) -> @location(0) vec4f {\n"
            "  return textureSample(t, s, v.uv);\n"
            "}\n";
        WGPUShaderSourceWGSL src = WGPU_SHADER_SOURCE_WGSL_INIT;
        src.chain.sType = WGPUSType_ShaderSourceWGSL;
        src.code = {kBlitWgsl, WGPU_STRLEN};
        WGPUShaderModuleDescriptor smd = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
        smd.nextInChain = &src.chain;
        smd.label = {"nwp_blit", WGPU_STRLEN};
        p->blitModule = wgpuDeviceCreateShaderModule(p->device, &smd);
        if (!p->blitModule) return nullptr;

        WGPUSamplerDescriptor sd = WGPU_SAMPLER_DESCRIPTOR_INIT;
        sd.magFilter = WGPUFilterMode_Linear;
        sd.minFilter = WGPUFilterMode_Linear;
        p->blitSampler = wgpuDeviceCreateSampler(p->device, &sd);

        WGPUColorTargetState target = WGPU_COLOR_TARGET_STATE_INIT;
        target.format = p->surfaceFormat;
        WGPUFragmentState frag = WGPU_FRAGMENT_STATE_INIT;
        frag.module = p->blitModule;
        frag.entryPoint = {"fs_main", WGPU_STRLEN};
        frag.targetCount = 1;
        frag.targets = &target;
        WGPURenderPipelineDescriptor rd = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
        rd.label = {"nwp_blit_pipeline", WGPU_STRLEN};
        rd.vertex.module = p->blitModule;
        rd.vertex.entryPoint = {"vs_main", WGPU_STRLEN};
        rd.primitive.topology = WGPUPrimitiveTopology_TriangleList;
        rd.multisample.count = 1;
        rd.fragment = &frag;
        p->blitPipeline = wgpuDeviceCreateRenderPipeline(p->device, &rd);
        if (!p->blitPipeline) return nullptr;
    }

    WGPUBindGroupLayout bgl =
        wgpuRenderPipelineGetBindGroupLayout(p->blitPipeline, 0);
    WGPUBindGroupEntry entries[2];
    entries[0] = WGPU_BIND_GROUP_ENTRY_INIT;
    entries[0].binding = 0;
    entries[0].sampler = p->blitSampler;
    entries[1] = WGPU_BIND_GROUP_ENTRY_INIT;
    entries[1].binding = 1;
    entries[1].textureView = p->offView;
    WGPUBindGroupDescriptor bd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
    bd.layout = bgl;
    bd.entryCount = 2;
    bd.entries = entries;
    p->blitBind = wgpuDeviceCreateBindGroup(p->device, &bd);
    wgpuBindGroupLayoutRelease(bgl);
    if (!p->blitBind) return nullptr;
    return p->offView;
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
    p->surfaceWidth = width;
    p->surfaceHeight = height;
}

void nwpDestroySurface(NwpPresenter* p) {
    // A view that unmounts mid-frame leaves the swapchain texture acquired
    // but never presented — wgpu panics if the surface drops while that
    // texture is outstanding. Present it (the view is disappearing; one
    // stale frame is invisible) before tearing the surface down.
    if (p->surface && p->surfaceView) {
        wgpuSurfacePresent(p->surface);
    }
    nwpReleaseSurfaceFrame(p);
    nwpReleaseBlit(p);
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

#ifdef __ANDROID__
// wgpu's GL backend cannot create an EGL swapchain on the Flutter
// SurfaceProducer (ImageReader) window — eglCreateWindowSurface fails with
// EGL_BAD_ALLOC and wgpu-native PANICS inside wgpuSurfaceConfigure,
// aborting the whole process. Detect GL up front so those devices take the
// CPU-readback fallback instead. (Vulkan-backed devices — every real
// modern Android GPU plus emulators with -gpu swiftshader_indirect — take
// the normal zero-copy path.)
bool nwpDeviceOnGlBackend(WGPUDevice device) {
    // NEVER query the device handle here — wgpuDeviceGetAdapterInfo is an
    // unimplemented!() panic stub in wgpu-native v29. The backend was
    // recorded from the adapter at requestDevice time.
    const WGPUBackendType backend = WgpuContext::get().deviceBackend(device);
    return backend == WGPUBackendType_OpenGL ||
           backend == WGPUBackendType_OpenGLES;
}

// GL-fallback frame delivery: copies a mapped ring frame into the
// ANativeWindow. Runs on the wgpu map-callback thread; serialized against
// window replace/park/destroy by surfaceMutex.
void nwpBlitToWindow(NwpPresenter* p, const uint8_t* pixels, int32_t width,
                     int32_t height, int32_t bytesPerRow) {
    std::lock_guard<std::mutex> lock(p->surfaceMutex);
    auto* win = (ANativeWindow*)p->nativeWindow;
    if (!win) return;  // parked (window lost) — drop the frame
    if (p->geomWidth != width || p->geomHeight != height) {
        // Buffers at the RENDER size; the compositor scales to the window,
        // so renderScale works with no extra blit.
        ANativeWindow_setBuffersGeometry(win, width, height,
                                         WINDOW_FORMAT_RGBA_8888);
        p->geomWidth = width;
        p->geomHeight = height;
    }
    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(win, &buf, nullptr) != 0) {
        if (!p->lockFailLogged) {
            p->lockFailLogged = true;
            __android_log_print(ANDROID_LOG_ERROR, "nwp",
                                "ANativeWindow_lock failed — the GL-backend "
                                "fallback cannot present on this window");
        }
        return;
    }
    const int32_t copyW = width < buf.width ? width : buf.width;
    const int32_t copyH = height < buf.height ? height : buf.height;
    auto* dst = (uint8_t*)buf.bits;
    for (int32_t y = 0; y < copyH; y++) {
        memcpy(dst + (size_t)y * (size_t)buf.stride * 4,
               pixels + (size_t)y * (size_t)bytesPerRow, (size_t)copyW * 4);
    }
    ANativeWindow_unlockAndPost(win);
}
#endif

// Builds a WGPUSurface for [window] and configures it at the current size.
bool nwpAttachWindow(NwpPresenter* p, void* window) {
#ifdef __ANDROID__
    // Safety net: a WGPUSurface must never be configured on the GL backend
    // (process-fatal panic) — GL presenters are created in readback mode
    // and never reach here.
    if (nwpDeviceOnGlBackend(p->device)) return false;
#endif
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
    nwpConfigureSurface(p, p->surfaceWidth, p->surfaceHeight);
    return true;
}

#if defined(NITRO_WEBGPU_BACKEND_DAWN) && (defined(__APPLE__) || defined(_WIN32))
// Zero-copy present: import the shim's IOSurface (cached), GPU-copy the
// ring slot into it, then notify the shim once the GPU finished. Runs on
// the Dart thread inside nwp_presenter_present; slot state is already 2.
void nwpPresentViaImport(int64_t token, NwpPresenter* p, int slot) {
    NwpSlot& s = p->slots[slot];
    void* surface = p->ioAcquire(token, p->width, p->height, p->ioUser);
    if (!surface) {
        nwpCompleteInflight(token, p, slot);
        return;
    }
    auto& imp = p->ioImports[surface];
    if (imp.mem && (imp.width != p->width || imp.height != p->height)) {
        // Same pointer, different geometry: the pool was rebuilt and the
        // address was reused — the cached import points at a dead surface.
        wgpuTextureRelease(imp.tex);
        wgpuSharedTextureMemoryRelease(imp.mem);
        imp = {};
    }
    if (!imp.mem) {
#if defined(__APPLE__)
        WGPUSharedTextureMemoryIOSurfaceDescriptor io =
            WGPU_SHARED_TEXTURE_MEMORY_IO_SURFACE_DESCRIPTOR_INIT;
        io.chain.sType = WGPUSType_SharedTextureMemoryIOSurfaceDescriptor;
        io.ioSurface = surface;
#else
        WGPUSharedTextureMemoryDXGISharedHandleDescriptor io =
            WGPU_SHARED_TEXTURE_MEMORY_DXGI_SHARED_HANDLE_DESCRIPTOR_INIT;
        io.chain.sType =
            WGPUSType_SharedTextureMemoryDXGISharedHandleDescriptor;
        io.handle = surface;
        io.useKeyedMutex = 0;
#endif
        WGPUSharedTextureMemoryDescriptor smd =
            WGPU_SHARED_TEXTURE_MEMORY_DESCRIPTOR_INIT;
        smd.nextInChain = &io.chain;
        imp.mem = wgpuDeviceImportSharedTextureMemory(p->device, &smd);
        // Null descriptor: Dawn derives the texture from the surface's
        // own properties (BGRA8, full usage).
        if (imp.mem) {
            imp.tex = wgpuSharedTextureMemoryCreateTexture(imp.mem, nullptr);
        }
        if (!imp.mem || !imp.tex) {
            if (imp.tex) wgpuTextureRelease(imp.tex);
            if (imp.mem) wgpuSharedTextureMemoryRelease(imp.mem);
            p->ioImports.erase(surface);
            nwpCompleteInflight(token, p, slot);
            return;
        }
        imp.width = p->width;
        imp.height = p->height;
    }

    WGPUSharedTextureMemoryBeginAccessDescriptor ba = {};
    // Contents are fully overwritten by the copy; claiming initialized
    // skips Dawn's lazy clear. No fences: the pool + drop-latest pacing
    // guarantee the compositor finished reading recycled buffers.
    ba.initialized = 1;
    if (wgpuSharedTextureMemoryBeginAccess(imp.mem, imp.tex, &ba) !=
        WGPUStatus_Success) {
        nwpCompleteInflight(token, p, slot);
        return;
    }

    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(p->device, &ed);
    WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
    src.texture = s.target;
    WGPUTexelCopyTextureInfo dst = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
    dst.texture = imp.tex;
    WGPUExtent3D extent = {(uint32_t)p->width, (uint32_t)p->height, 1};
    wgpuCommandEncoderCopyTextureToTexture(encoder, &src, &dst, &extent);
    WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(encoder, nullptr);
    wgpuQueueSubmit(p->queue, 1, &cmd);
    wgpuCommandBufferRelease(cmd);
    wgpuCommandEncoderRelease(encoder);

    WGPUSharedTextureMemoryEndAccessState ea = {};
    if (wgpuSharedTextureMemoryEndAccess(imp.mem, imp.tex, &ea) ==
        WGPUStatus_Success) {
        wgpuSharedTextureMemoryEndAccessStateFreeMembers(ea);
    }

    struct IoPresentOp {
        NwpPresenter* p;
        int64_t token;
        int slot;
        void* surface;
    };
    auto* op = new IoPresentOp{p, token, slot, surface};
    WGPUQueueWorkDoneCallbackInfo wcb = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
    wcb.mode = WGPUCallbackMode_AllowProcessEvents;
    wcb.userdata1 = op;
    wcb.callback = [](WGPUQueueWorkDoneStatus status, WGPUStringView,
                      void* ud1, void*) {
        auto* op = static_cast<IoPresentOp*>(ud1);
        NwpPresenter* p = op->p;
        if (status == WGPUQueueWorkDoneStatus_Success && p->ioPresented) {
            p->ioPresented(op->token, op->surface, p->ioUser);
        }
        nwpCompleteInflight(op->token, p, op->slot);
        WgpuContext::get().opFinished();
        delete op;
    };
    wgpuQueueOnSubmittedWorkDone(p->queue, wcb);
    WgpuContext::get().opStarted();
}
#endif

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
#ifdef __ANDROID__
    if (nwpDeviceOnGlBackend((WGPUDevice)(intptr_t)deviceAddress)) {
        // GL fallback: ring/readback presenter + CPU blit into the window.
        auto* p = new NwpPresenter();
        p->androidReadback = true;
        p->ringFormat = WGPUTextureFormat_RGBA8Unorm;
        p->device = (WGPUDevice)(intptr_t)deviceAddress;
        p->queue = wgpuDeviceGetQueue(p->device);
        p->surfaceWidth = width;
        p->surfaceHeight = height;
        if (!p->queue || !nwpCreateTargets(p, width, height)) {
            nwpReleaseTargets(p);
            if (p->queue) wgpuQueueRelease(p->queue);
            delete p;
            return 0;
        }
        p->nativeWindow = nativeWindow;  // ownership transfers
        __android_log_print(
            ANDROID_LOG_INFO, "nwp",
            "GL backend (no Vulkan): presenting via CPU readback fallback "
            "(%dx%d) — expect reduced throughput; emulators can enable "
            "Vulkan with -gpu swiftshader_indirect",
            width, height);
        WgpuContext::get().registerDevice(p->device);
        std::lock_guard<std::mutex> lock(gPresentersMutex);
        const int64_t token = gNextPresenterToken++;
        gPresenters[token] = p;
        return token;
    }
#endif
    auto* p = new NwpPresenter();
    p->surfaceMode = true;
    p->device = (WGPUDevice)(intptr_t)deviceAddress;
    p->queue = wgpuDeviceGetQueue(p->device);
    p->width = width;
    p->height = height;
    p->surfaceWidth = width;
    p->surfaceHeight = height;
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

void nwp_presenter_replace_surface(int64_t token, void* nativeWindow,
                                   int32_t width, int32_t height) {
    NwpPresenter* p = nwpFindAndRef(token);
    if (!p) return;
    NwpOpGuard guard{token, p};
#ifdef __ANDROID__
    if (p->androidReadback) {
        std::lock_guard<std::mutex> surfLock(p->surfaceMutex);
        if (p->nativeWindow) {
            ANativeWindow_release((ANativeWindow*)p->nativeWindow);
        }
        p->nativeWindow = nativeWindow;  // may be null → parked
        p->geomWidth = 0;  // re-assert buffer geometry on the next blit
        p->geomHeight = 0;
        if (width > 0 && height > 0) {
            p->surfaceWidth = width;
            p->surfaceHeight = height;
        }
        return;
    }
#endif
    if (!p->surfaceMode) return;
    std::lock_guard<std::mutex> surfLock(p->surfaceMutex);
    nwpDestroySurface(p);
    if (width > 0 && height > 0) {
        p->surfaceWidth = width;
        p->surfaceHeight = height;
    }
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
#if defined(NITRO_WEBGPU_BACKEND_DAWN)
    // Dawn presents via SharedTextureMemory import (P2 of the migration),
    // not exported Metal handles.
    return nullptr;
#else
    return wgpuDeviceGetNativeMetalDevice(p->device);
#endif
}

int64_t nwp_presenter_acquire(int64_t token) {
    NwpPresenter* p = nwpFindAndRef(token);
    if (!p) return 0;
    NwpOpGuard guard{token, p};

    if (p->surfaceMode) {
        std::lock_guard<std::mutex> surfLock(p->surfaceMutex);
        if (!p->surface) return 0;  // parked (window lost)
        // Pending RENDER resize: only the internal target changes.
        if (p->pendingWidth > 0 &&
            (p->pendingWidth != p->width || p->pendingHeight != p->height)) {
            p->width = p->pendingWidth;
            p->height = p->pendingHeight;
            p->pendingWidth = 0;
            p->pendingHeight = 0;
            nwpReleaseOffscreen(p);
        }
        // Scaled path: render into the internal target; blit at present.
        if (p->width != p->surfaceWidth || p->height != p->surfaceHeight) {
            WGPUTextureView view = nwpEnsureOffscreen(p);
            if (!view) return 0;
            p->offscreenAcquired = true;
            return (int64_t)(intptr_t)view;
        }
        p->offscreenAcquired = false;
        if (p->surfaceView) return (int64_t)(intptr_t)p->surfaceView;
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
                nwpConfigureSurface(p, p->surfaceWidth, p->surfaceHeight);
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
    NwpPresenter* p = nwpFindAndRef(token);
    if (!p) return;
    NwpOpGuard guard{token, p};

    if (p->surfaceMode) {
        std::lock_guard<std::mutex> surfLock(p->surfaceMutex);
        if (!p->surface) return;
        if (p->offscreenAcquired) {
            // Scaled path: fetch the swapchain image now, upscale-blit the
            // internal target into it, then present.
            p->offscreenAcquired = false;
            WGPUSurfaceTexture st = WGPU_SURFACE_TEXTURE_INIT;
            wgpuSurfaceGetCurrentTexture(p->surface, &st);
            if (st.status != WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal &&
                st.status != WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal) {
                if (st.texture) wgpuTextureRelease(st.texture);
                return;  // drop this frame; next acquire may reconfigure
            }
            WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
            WGPUTextureView dst = wgpuTextureCreateView(st.texture, &vd);
            if (dst) {
                WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
                WGPUCommandEncoder enc =
                    wgpuDeviceCreateCommandEncoder(p->device, &ed);
                WGPURenderPassColorAttachment att =
                    WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
                att.view = dst;
                att.loadOp = WGPULoadOp_Clear;
                att.storeOp = WGPUStoreOp_Store;
                WGPURenderPassDescriptor rp = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
                rp.colorAttachmentCount = 1;
                rp.colorAttachments = &att;
                WGPURenderPassEncoder pass =
                    wgpuCommandEncoderBeginRenderPass(enc, &rp);
                wgpuRenderPassEncoderSetPipeline(pass, p->blitPipeline);
                wgpuRenderPassEncoderSetBindGroup(pass, 0, p->blitBind, 0,
                                                  nullptr);
                wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
                wgpuRenderPassEncoderEnd(pass);
                wgpuRenderPassEncoderRelease(pass);
                WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(enc, nullptr);
                wgpuQueueSubmit(p->queue, 1, &cmd);
                wgpuCommandBufferRelease(cmd);
                wgpuCommandEncoderRelease(enc);
                wgpuSurfacePresent(p->surface);
                wgpuTextureViewRelease(dst);
            }
            wgpuTextureRelease(st.texture);
            return;
        }
        if (!p->surfaceView) return;
        wgpuSurfacePresent(p->surface);
        nwpReleaseSurfaceFrame(p);
        return;
    }

    const int slot = p->acquiredSlot;
    if (slot < 0 || slot >= kNwpSlots) return;
    int expected = 1;
    if (!p->slots[slot].state.compare_exchange_strong(expected, 2)) return;
    p->acquiredSlot = -1;

#if defined(NITRO_WEBGPU_BACKEND_DAWN) && (defined(__APPLE__) || defined(_WIN32))
    if (p->ioAcquire) {
        nwpPresentViaImport(token, p, slot);
        return;
    }
#endif
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
#if !defined(NITRO_WEBGPU_BACKEND_DAWN)
            if (status == WGPUQueueWorkDoneStatus_Success && p->gpuSink) {
                mtl = wgpuTextureGetNativeMetalTexture(p->slots[op->slot].target);
            }
#else
            (void)status;
#endif
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
#ifdef __ANDROID__
            if (mapped && p->androidReadback) {
                nwpBlitToWindow(p, (const uint8_t*)mapped, p->width,
                                p->height, p->alignedBytesPerRow);
            }
#endif
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
    if (!p) return (int32_t)kNwpRingFormat;
    return (int32_t)(p->surfaceMode ? p->surfaceFormat : p->ringFormat);
}

int32_t nwp_presenter_is_surface_mode(int64_t token) {
    NwpPresenter* p = nwpFind(token);
    return (p && p->surfaceMode) ? 1 : 0;
}

int32_t nwp_presenter_supports_texture_import(int64_t token) {
#if defined(NITRO_WEBGPU_BACKEND_DAWN) && (defined(__APPLE__) || defined(_WIN32))
    NwpPresenter* p = nwpFind(token);
#if defined(__APPLE__)
    const WGPUFeatureName kImport = WGPUFeatureName_SharedTextureMemoryIOSurface;
#else
    const WGPUFeatureName kImport =
        WGPUFeatureName_SharedTextureMemoryDXGISharedHandle;
#endif
    return (p && wgpuDeviceHasFeature(p->device, kImport)) ? 1 : 0;
#else
    (void)token;
    return 0;
#endif
}

void nwp_presenter_set_import_ops(int64_t token,
                                  NwpImportAcquire acquire,
                                  NwpImportPresented presented,
                                  void* user) {
#if defined(NITRO_WEBGPU_BACKEND_DAWN) && (defined(__APPLE__) || defined(_WIN32))
    NwpPresenter* p = nwpFind(token);
    if (!p) return;
    p->ioAcquire = acquire;
    p->ioPresented = presented;
    p->ioUser = user;
#else
    (void)token;
    (void)acquire;
    (void)presented;
    (void)user;
#endif
}

void nwp_presenter_resize(int64_t token, int32_t width, int32_t height) {
    NwpPresenter* p = nwpFindAndRef(token);
    if (!p) return;
    NwpOpGuard guard{token, p};
    if (width <= 0 || height <= 0) return;
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
        busy = nwpAnyInflight(p) ||
               p->opRefs.load(std::memory_order_acquire) > 0;
    }
    // Presents still in flight: the last completion (map callback, workdone
    // failure path, or frame_done) finalizes the presenter — never freeing
    // memory a pending callback might still touch.
    if (!busy) nwpFinalize(token, p);
}

}  // extern "C"
