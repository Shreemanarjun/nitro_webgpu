// C ABI of the shared presentation core (src/present/present_core.cpp,
// compiled into the core nitro_webgpu library). Platform shims (Swift/Kotlin
// plugin code) drive presenters through these functions; wgpu-native state
// stays inside the one core library.
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
/// GPU work has completed. The shim then blits the render target's native
/// texture itself and MUST call nwp_presenter_frame_done when the blit has
/// been scheduled/completed — until then acquire returns 0.
typedef void (*NwpGpuFrameSink)(int64_t token, int32_t width, int32_t height,
                                void* user);

/// Creates a presenter on the WGPUDevice at [deviceAddress]. Returns a
/// non-zero token, or 0 on failure.
NWP_EXPORT int64_t nwp_presenter_create(int64_t deviceAddress, int32_t width,
                                        int32_t height);

NWP_EXPORT void nwp_presenter_set_sink(int64_t token, NwpFrameSink sink,
                                       void* user);

/// Selects the GPU presentation path (Metal blit) instead of CPU readback.
NWP_EXPORT void nwp_presenter_set_gpu_sink(int64_t token, NwpGpuFrameSink sink,
                                           void* user);

/// GPU path only: marks the in-flight frame as fully presented, making the
/// render target available for the next acquire. Callable from any thread.
NWP_EXPORT void nwp_presenter_frame_done(int64_t token);

/// Borrowed `id<MTLTexture>` of the current render target (NULL off-Metal or
/// unknown token). Valid until the next resize-applying acquire.
NWP_EXPORT void* nwp_presenter_target_metal_texture(int64_t token);

/// Borrowed `id<MTLDevice>` of the presenter's device (NULL off-Metal).
NWP_EXPORT void* nwp_presenter_metal_device(int64_t token);

/// Returns the WGPUTextureView address to render this frame into, or 0 to
/// skip (previous frame still in flight / unknown token).
NWP_EXPORT int64_t nwp_presenter_acquire(int64_t token);

/// Kicks off readback of the last acquired frame; the sink fires when the
/// GPU copy completes.
NWP_EXPORT void nwp_presenter_present(int64_t token);

/// Raw WGPUTextureFormat of the render target (BGRA8Unorm).
NWP_EXPORT int32_t nwp_presenter_format(int64_t token);

/// Requests a resize; applied on the next acquire.
NWP_EXPORT void nwp_presenter_resize(int64_t token, int32_t width,
                                     int32_t height);

/// 1 while a readback is in flight (destroy must wait for 0).
NWP_EXPORT int32_t nwp_presenter_is_busy(int64_t token);

/// Tears down the presenter. Must not be called while busy.
NWP_EXPORT void nwp_presenter_destroy(int64_t token);

#ifdef __cplusplus
}
#endif
