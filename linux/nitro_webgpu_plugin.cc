// Linux presentation plugin (M2.5).
//
// Owns the Flutter texture objects for the CPU-readback presenter: the Nitro
// present module (src/HybridNitroWebgpuPresent.cpp, in
// libnitro_webgpu_present.so) cannot see Flutter headers, so this plugin
// installs an NwpTextureOps table at engine startup and services it with
// FlPixelBufferTexture instances.
#include "include/nitro_webgpu/nitro_webgpu_plugin.h"

#include <cstring>
#include <mutex>
#include <vector>

#include "../src/present/nwp_texture_ops.h"

// ── Pixel-buffer texture ─────────────────────────────────────────────────
// The readback sink thread writes into `pending`; the engine's raster thread
// swaps it into `visible` inside copy_pixels — `visible` is only ever
// touched there, so the returned pointer stays stable until the next
// copy_pixels call.

struct _NwpTexture {
  FlPixelBufferTexture parent_instance;

  std::mutex* mutex;
  std::vector<uint8_t>* pending;
  std::vector<uint8_t>* visible;
  int32_t pending_width;
  int32_t pending_height;
  int32_t visible_width;
  int32_t visible_height;
  bool has_pending;
};

#define NWP_TYPE_TEXTURE nwp_texture_get_type()
G_DECLARE_FINAL_TYPE(NwpTexture, nwp_texture, NWP, TEXTURE,
                     FlPixelBufferTexture)
G_DEFINE_TYPE(NwpTexture, nwp_texture, fl_pixel_buffer_texture_get_type())

// The buffer handed back must be RGBA — which is exactly what the readback
// ring renders on desktop Linux (kNwpRingFormat = RGBA8Unorm).
static gboolean nwp_texture_copy_pixels(FlPixelBufferTexture* texture,
                                        const uint8_t** out_buffer,
                                        uint32_t* width, uint32_t* height,
                                        GError** error) {
  NwpTexture* self = NWP_TEXTURE(texture);
  std::lock_guard<std::mutex> lock(*self->mutex);
  if (self->has_pending) {
    self->visible->swap(*self->pending);
    self->visible_width = self->pending_width;
    self->visible_height = self->pending_height;
    self->has_pending = false;
  }
  if (self->visible->empty()) {
    g_set_error(error, g_quark_from_static_string("nitro_webgpu"), 1,
                "no frame presented yet");
    return FALSE;
  }
  *out_buffer = self->visible->data();
  *width = (uint32_t)self->visible_width;
  *height = (uint32_t)self->visible_height;
  return TRUE;
}

static void nwp_texture_dispose(GObject* object) {
  NwpTexture* self = NWP_TEXTURE(object);
  delete self->mutex;
  delete self->pending;
  delete self->visible;
  self->mutex = nullptr;
  self->pending = nullptr;
  self->visible = nullptr;
  G_OBJECT_CLASS(nwp_texture_parent_class)->dispose(object);
}

static void nwp_texture_class_init(NwpTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = nwp_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->dispose = nwp_texture_dispose;
}

static void nwp_texture_init(NwpTexture* self) {
  self->mutex = new std::mutex();
  self->pending = new std::vector<uint8_t>();
  self->visible = new std::vector<uint8_t>();
  self->pending_width = 0;
  self->pending_height = 0;
  self->visible_width = 0;
  self->visible_height = 0;
  self->has_pending = false;
}

// ── NwpTextureOps implementation ─────────────────────────────────────────

namespace {

struct NwpLinuxContext {
  FlTextureRegistrar* registrar;  // owned (+1 ref)
};

int64_t ops_register_texture(void* ctx, void** out_handle) {
  auto* context = static_cast<NwpLinuxContext*>(ctx);
  NwpTexture* texture = NWP_TEXTURE(g_object_new(NWP_TYPE_TEXTURE, nullptr));
  fl_texture_registrar_register_texture(context->registrar,
                                        FL_TEXTURE(texture));
  *out_handle = texture;
  return fl_texture_get_id(FL_TEXTURE(texture));
}

void ops_publish_frame(void* ctx, void* handle, const uint8_t* pixels,
                       int32_t width, int32_t height, int32_t bytes_per_row) {
  auto* context = static_cast<NwpLinuxContext*>(ctx);
  auto* texture = static_cast<NwpTexture*>(handle);
  {
    std::lock_guard<std::mutex> lock(*texture->mutex);
    texture->pending->resize((size_t)width * height * 4);
    for (int32_t row = 0; row < height; ++row) {
      std::memcpy(texture->pending->data() + (size_t)row * width * 4,
                  pixels + (size_t)row * bytes_per_row, (size_t)width * 4);
    }
    texture->pending_width = width;
    texture->pending_height = height;
    texture->has_pending = true;
  }
  fl_texture_registrar_mark_texture_frame_available(context->registrar,
                                                    FL_TEXTURE(texture));
}

void ops_unregister_texture(void* ctx, void* handle) {
  auto* context = static_cast<NwpLinuxContext*>(ctx);
  auto* texture = static_cast<NwpTexture*>(handle);
  fl_texture_registrar_unregister_texture(context->registrar,
                                          FL_TEXTURE(texture));
  g_object_unref(texture);
}

}  // namespace

void nitro_webgpu_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  auto* context = new NwpLinuxContext();
  context->registrar = FL_TEXTURE_REGISTRAR(
      g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)));
  static NwpTextureOps ops{};
  ops.ctx = context;
  ops.register_texture = &ops_register_texture;
  ops.publish_frame = &ops_publish_frame;
  ops.unregister_texture = &ops_unregister_texture;
  nwp_set_texture_ops(&ops);
}
