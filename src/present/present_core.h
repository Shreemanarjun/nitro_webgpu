// C ABI of the shared presentation core (src/present/present_core.cpp,
// compiled into the core nitro_webgpu library). Platform shims (Swift/Kotlin
// plugin code) drive presenters through these functions; wgpu-native state
// stays inside the one core library.
//
// The presenter keeps a small ring of render targets so frames pipeline:
// frame N+1 renders while frame N's blit/readback is still in flight —
// throughput approaches 1 / gpu-pass-time instead of being serialized on the
// full submit→complete→present round trip.
#pragma once
#include <stdint.h>

#if defined(_WIN32)
#define NWP_EXPORT __declspec(dllexport)
#else
#define NWP_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// Called on a wgpu callback thread with the mapped, tightly-row-aligned
/// pixels of a presented frame. The pointer is only valid for the duration of
/// the call — copy synchronously (e.g. into a CVPixelBuffer).
typedef void (*NwpFrameSink)(int64_t token, const uint8_t* pixels,
                             int32_t width, int32_t height,
                             int32_t bytesPerRow, void* user);

/// GPU-path sink: called on a wgpu callback thread once the presented frame's
/// GPU work has completed. [metalTexture] is the borrowed `id<MTLTexture>` of
/// the slot's render target. The shim blits it and MUST call
/// nwp_presenter_frame_done(token, slot) when the blit has completed — until
/// then that slot is unavailable to acquire (other slots keep the pipeline
/// full).
typedef void (*NwpGpuFrameSink)(int64_t token, int32_t width, int32_t height,
                                void* metalTexture, int32_t slot, void* user);

/// Creates a presenter on the WGPUDevice at [deviceAddress]. Returns a
/// non-zero token, or 0 on failure.
NWP_EXPORT int64_t nwp_presenter_create(int64_t deviceAddress, int32_t width,
                                        int32_t height);

/// Creates a presenter that renders into a real `WGPUSurface` built from a
/// platform native window (Android: `ANativeWindow*`) — the zero-copy path:
/// acquire returns the swapchain texture's view, present calls
/// `wgpuSurfacePresent`. The presenter takes ownership of the window
/// reference. Returns a non-zero token, or 0 on failure.
NWP_EXPORT int64_t nwp_presenter_create_surface(int64_t deviceAddress,
                                                void* nativeWindow,
                                                int32_t width, int32_t height);

/// Swaps the presenter's backing window (Android `SurfaceProducer`
/// re-created its Surface). NULL parks the presenter (acquire returns 0)
/// until a window arrives.
NWP_EXPORT void nwp_presenter_replace_surface(int64_t token,
                                              void* nativeWindow);

NWP_EXPORT void nwp_presenter_set_sink(int64_t token, NwpFrameSink sink,
                                       void* user);

/// Selects the GPU presentation path (Metal blit) instead of CPU readback.
NWP_EXPORT void nwp_presenter_set_gpu_sink(int64_t token, NwpGpuFrameSink sink,
                                           void* user);

/// GPU path only: releases [slot] back to the ring after the shim's blit
/// completed. Callable from any thread.
NWP_EXPORT void nwp_presenter_frame_done(int64_t token, int32_t slot);

/// Borrowed `id<MTLDevice>` of the presenter's device (NULL off-Metal).
NWP_EXPORT void* nwp_presenter_metal_device(int64_t token);

/// Returns the WGPUTextureView address to render this frame into, or 0 to
/// skip (every slot busy / resizing / unknown token).
NWP_EXPORT int64_t nwp_presenter_acquire(int64_t token);

/// Kicks off presentation of the last acquired slot; the sink fires when the
/// GPU work completes.
NWP_EXPORT void nwp_presenter_present(int64_t token);

/// Raw WGPUTextureFormat of the render target (BGRA8Unorm).
NWP_EXPORT int32_t nwp_presenter_format(int64_t token);

/// Requests a resize; applied on the next acquire with a fully idle ring.
NWP_EXPORT void nwp_presenter_resize(int64_t token, int32_t width,
                                     int32_t height);

/// 1 while any slot has a present in flight (destroy must wait for 0).
NWP_EXPORT int32_t nwp_presenter_is_busy(int64_t token);

/// Tears down the presenter (deferred safely if a present is in flight).
NWP_EXPORT void nwp_presenter_destroy(int64_t token);

#ifdef __cplusplus
}
#endif
