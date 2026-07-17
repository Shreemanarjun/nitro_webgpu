// Windows presentation plugin (M2.4).
//
// Owns the Flutter texture objects for the CPU-readback presenter: the Nitro
// present module (src/HybridNitroWebgpuPresent.cpp, in
// nitro_webgpu_present.dll) cannot see Flutter headers, so this plugin
// installs an NwpTextureOps table at engine startup and services it with
// flutter::PixelBufferTexture instances.
#include "include/nitro_webgpu/nitro_webgpu_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>
#include <flutter/texture_registrar.h>

#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

#include "../src/present/nwp_texture_ops.h"

namespace {

// One Flutter pixel-buffer texture fed by the readback sink. The sink thread
// writes into `pending_`; the engine's raster thread swaps it into
// `visible_` inside CopyPixels — `visible_` is only ever touched there, so
// the returned pointer stays stable until the next CopyPixels call.
class WinPresentTexture {
 public:
  explicit WinPresentTexture(flutter::TextureRegistrar* registrar)
      : registrar_(registrar),
        texture_(flutter::PixelBufferTexture(
            [this](size_t /*width*/, size_t /*height*/) {
              return CopyPixels();
            })) {
    texture_id_ = registrar_->RegisterTexture(&texture_);
  }

  int64_t texture_id() const { return texture_id_; }

  // Any thread. Copies the mapped readback rows (bytes_per_row apart,
  // 256-aligned) into a tightly-packed RGBA buffer.
  void Publish(const uint8_t* pixels, int32_t width, int32_t height,
               int32_t bytes_per_row) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      pending_.resize(static_cast<size_t>(width) * height * 4);
      for (int32_t row = 0; row < height; ++row) {
        std::memcpy(pending_.data() + static_cast<size_t>(row) * width * 4,
                    pixels + static_cast<size_t>(row) * bytes_per_row,
                    static_cast<size_t>(width) * 4);
      }
      pending_width_ = width;
      pending_height_ = height;
      has_pending_ = true;
    }
    registrar_->MarkTextureFrameAvailable(texture_id_);
  }

  // Any thread. Deletes `this` once the engine confirms the texture is gone.
  void Unregister() {
    registrar_->UnregisterTexture(texture_id_, [this]() { delete this; });
  }

 private:
  const FlutterDesktopPixelBuffer* CopyPixels() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (has_pending_) {
      visible_.swap(pending_);
      visible_width_ = pending_width_;
      visible_height_ = pending_height_;
      has_pending_ = false;
    }
    if (visible_.empty()) return nullptr;
    buffer_.buffer = visible_.data();
    buffer_.width = static_cast<size_t>(visible_width_);
    buffer_.height = static_cast<size_t>(visible_height_);
    buffer_.release_callback = nullptr;
    buffer_.release_context = nullptr;
    return &buffer_;
  }

  flutter::TextureRegistrar* registrar_;
  flutter::TextureVariant texture_;
  int64_t texture_id_ = 0;
  std::mutex mutex_;
  std::vector<uint8_t> pending_;
  std::vector<uint8_t> visible_;
  int32_t pending_width_ = 0;
  int32_t pending_height_ = 0;
  int32_t visible_width_ = 0;
  int32_t visible_height_ = 0;
  bool has_pending_ = false;
  FlutterDesktopPixelBuffer buffer_{};
};

class NitroWebgpuPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar) {
    auto plugin =
        std::make_unique<NitroWebgpuPlugin>(registrar->texture_registrar());
    static NwpTextureOps ops{};
    ops.ctx = plugin.get();
    ops.register_texture = &OpsRegisterTexture;
    ops.publish_frame = &OpsPublishFrame;
    ops.unregister_texture = &OpsUnregisterTexture;
    nwp_set_texture_ops(&ops);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit NitroWebgpuPlugin(flutter::TextureRegistrar* textures)
      : textures_(textures) {}

  ~NitroWebgpuPlugin() override { nwp_set_texture_ops(nullptr); }

  flutter::TextureRegistrar* textures() const { return textures_; }

 private:
  static int64_t OpsRegisterTexture(void* ctx, void** out_handle) {
    auto* plugin = static_cast<NitroWebgpuPlugin*>(ctx);
    auto* texture = new WinPresentTexture(plugin->textures());
    *out_handle = texture;
    return texture->texture_id();
  }

  static void OpsPublishFrame(void* /*ctx*/, void* handle,
                              const uint8_t* pixels, int32_t width,
                              int32_t height, int32_t bytes_per_row) {
    static_cast<WinPresentTexture*>(handle)->Publish(pixels, width, height,
                                                     bytes_per_row);
  }

  static void OpsUnregisterTexture(void* /*ctx*/, void* handle) {
    static_cast<WinPresentTexture*>(handle)->Unregister();
  }

  flutter::TextureRegistrar* textures_;
};

}  // namespace

void NitroWebgpuPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  NitroWebgpuPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
