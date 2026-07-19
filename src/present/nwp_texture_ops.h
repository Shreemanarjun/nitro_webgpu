// Desktop (Windows/Linux) texture-registry handoff.
//
// The Nitro present module (src/HybridNitroWebgpuPresent.cpp, compiled into
// the nitro_webgpu_present library) cannot see Flutter embedder headers; the
// platform plugin (windows/nitro_webgpu_plugin.cpp,
// linux/nitro_webgpu_plugin.cc) owns the Flutter texture objects. The plugin
// installs this ops table at engine startup via nwp_set_texture_ops(); the
// present module drives it token-by-token.
#pragma once
#include <stdint.h>

#if defined(_WIN32)
#if defined(NWP_PRESENT_BUILD)
#define NWP_TEXOPS_EXPORT __declspec(dllexport)
#else
#define NWP_TEXOPS_EXPORT __declspec(dllimport)
#endif
#else
#define NWP_TEXOPS_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NwpTextureOps {
    void* ctx;

    /// Registers a Flutter pixel-buffer texture. Returns the texture id for
    /// the `Texture` widget and stores an opaque per-texture handle in
    /// [out_handle]. Called on the platform thread (desktop Dart thread).
    int64_t (*register_texture)(void* ctx, void** out_handle);

    /// Publishes one RGBA frame: copy [height] rows of [width]*4 bytes
    /// (source rows are [bytes_per_row] apart — 256-aligned) synchronously,
    /// then mark the texture frame available. Called on a wgpu callback
    /// thread; the pixel pointer is only valid for the duration of the call.
    void (*publish_frame)(void* ctx, void* handle, const uint8_t* pixels,
                          int32_t width, int32_t height,
                          int32_t bytes_per_row);

    /// Unregisters the texture. The plugin frees the handle once the engine
    /// confirms; the caller never touches [handle] again. Any thread.
    void (*unregister_texture)(void* ctx, void* handle);

    /// OPTIONAL zero-copy path (Dawn backend): returns the platform shared
    /// object for [handle]'s texture at [width]x[height] (Windows: the DXGI
    /// shared HANDLE of a MISC_SHARED D3D11 texture), or NULL when
    /// unavailable. The core imports it and GPU-copies frames into it.
    void* (*acquire_shared_handle)(void* ctx, void* handle, int32_t width,
                                   int32_t height);

    /// OPTIONAL zero-copy path: the GPU finished writing the shared
    /// texture — publish the frame (MarkTextureFrameAvailable).
    void (*frame_presented)(void* ctx, void* handle);
} NwpTextureOps;

/// Exported by the nitro_webgpu_present library. The ops struct is copied;
/// pass NULL to uninstall (engine shutdown).
NWP_TEXOPS_EXPORT void nwp_set_texture_ops(const NwpTextureOps* ops);

#ifdef __cplusplus
}
#endif
