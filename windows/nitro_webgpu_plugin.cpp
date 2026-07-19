// Windows presentation plugin (M2.4 readback → M2.6 DXGI path).
//
// Owns the Flutter texture objects for the desktop presenter: the Nitro
// present module (src/HybridNitroWebgpuPresent.cpp, in
// nitro_webgpu_present.dll) cannot see Flutter headers, so this plugin
// installs an NwpTextureOps table at engine startup.
//
// Preferred path — DXGI shared-handle GPU surface: frames land in a
// D3D11_RESOURCE_MISC_SHARED texture via one UpdateSubresource (the
// 256-aligned mapped rows upload directly; no repacking), and the engine's
// compositor samples that texture through ANGLE with ZERO raster-thread
// upload. When upstream wgpu-native grows D3D12 handle accessors (it has
// them for Metal only today), the CPU upload becomes a GPU copy and
// everything downstream of it stays as-is.
//
// Fallback — flutter::PixelBufferTexture with a CPU double buffer, used
// only if D3D11 device creation fails.
#include "include/nitro_webgpu/nitro_webgpu_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>
#include <flutter/texture_registrar.h>

#include <d3d11.h>
#include <wrl/client.h>

#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

#include "../src/present/nwp_texture_ops.h"

namespace {

using Microsoft::WRL::ComPtr;

class PresentTextureBase {
 public:
  virtual ~PresentTextureBase() = default;
  virtual int64_t texture_id() const = 0;
  virtual void Publish(const uint8_t* pixels, int32_t width, int32_t height,
                       int32_t bytes_per_row) = 0;
  // Zero-copy path (Dawn): shared handle of the texture at the given size,
  // or nullptr when this texture type can't provide one.
  virtual void* AcquireSharedHandle(int32_t /*width*/, int32_t /*height*/) {
    return nullptr;
  }
  // Zero-copy path: the GPU finished writing the shared texture.
  virtual void FramePresented() {}
  // Deletes `this` once the engine confirms the texture is gone.
  virtual void Unregister() = 0;
};

// Plugin-wide D3D11 device shared by every presenter texture. The immediate
// context is not thread-safe — Publish calls (wgpu callback thread) hold
// [mutex] around every context use.
struct D3dShared {
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  std::mutex mutex;

  bool Init() {
    if (device) return true;
    // Hardware first; WARP keeps CI / GPU-less machines working.
    static const D3D_DRIVER_TYPE kDrivers[] = {D3D_DRIVER_TYPE_HARDWARE,
                                               D3D_DRIVER_TYPE_WARP};
    for (auto driver : kDrivers) {
      const HRESULT hr = D3D11CreateDevice(
          nullptr, driver, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION,
          device.ReleaseAndGetAddressOf(), nullptr,
          context.ReleaseAndGetAddressOf());
      if (SUCCEEDED(hr)) return true;
    }
    device.Reset();
    context.Reset();
    return false;
  }
};

// DXGI shared-handle texture: one MISC_SHARED D3D11 texture per presenter
// (recreated on resize; the previous one is retired for a frame so an
// in-flight engine open never races the release).
class WinDxgiTexture : public PresentTextureBase {
 public:
  WinDxgiTexture(flutter::TextureRegistrar* registrar, D3dShared* d3d)
      : registrar_(registrar),
        d3d_(d3d),
        texture_(flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
            [this](size_t /*width*/, size_t /*height*/) {
              return ObtainDescriptor();
            })) {
    texture_id_ = registrar_->RegisterTexture(&texture_);
  }

  int64_t texture_id() const override { return texture_id_; }

  void Publish(const uint8_t* pixels, int32_t width, int32_t height,
               int32_t bytes_per_row) override {
    std::lock_guard<std::mutex> d3d_lock(d3d_->mutex);
    if (width != width_ || height != height_) {
      if (!Recreate(width, height)) return;
    }
    d3d_->context->UpdateSubresource(shared_texture_.Get(), 0, nullptr,
                                     pixels,
                                     static_cast<UINT>(bytes_per_row), 0);
    d3d_->context->Flush();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      descriptor_.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
      descriptor_.handle = shared_handle_;
      descriptor_.width = static_cast<size_t>(width);
      descriptor_.height = static_cast<size_t>(height);
      descriptor_.visible_width = static_cast<size_t>(width);
      descriptor_.visible_height = static_cast<size_t>(height);
      descriptor_.format = kFlutterDesktopPixelFormatRGBA8888;
      descriptor_.release_callback = nullptr;
      descriptor_.release_context = nullptr;
      has_frame_ = true;
    }
    registrar_->MarkTextureFrameAvailable(texture_id_);
  }

  void* AcquireSharedHandle(int32_t width, int32_t height) override {
    std::lock_guard<std::mutex> d3d_lock(d3d_->mutex);
    if (width != width_ || height != height_) {
      if (!Recreate(width, height)) return nullptr;
    }
    return shared_handle_;
  }

  void FramePresented() override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      descriptor_.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
      descriptor_.handle = shared_handle_;
      descriptor_.width = static_cast<size_t>(width_);
      descriptor_.height = static_cast<size_t>(height_);
      descriptor_.visible_width = static_cast<size_t>(width_);
      descriptor_.visible_height = static_cast<size_t>(height_);
      descriptor_.format = kFlutterDesktopPixelFormatRGBA8888;
      descriptor_.release_callback = nullptr;
      descriptor_.release_context = nullptr;
      has_frame_ = true;
    }
    registrar_->MarkTextureFrameAvailable(texture_id_);
  }

  void Unregister() override {
    registrar_->UnregisterTexture(texture_id_, [this]() { delete this; });
  }

 private:
  // Raster thread. The engine opens the shared handle once and keeps its own
  // reference; it re-opens whenever the handle value changes (resize).
  // Returns a raster-thread-owned snapshot: descriptor_ can be rewritten by
  // Publish/FramePresented on the wgpu callback thread after the lock
  // drops, and the engine reads the pointer post-return.
  const FlutterDesktopGpuSurfaceDescriptor* ObtainDescriptor() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!has_frame_) return nullptr;
    visible_descriptor_ = descriptor_;
    return &visible_descriptor_;
  }

  // d3d_->mutex held.
  bool Recreate(int32_t width, int32_t height) {
    retired_ = shared_texture_;  // keep alive across an in-flight open
    shared_texture_.Reset();
    shared_handle_ = nullptr;

    D3D11_TEXTURE2D_DESC desc = {};
    desc.Width = static_cast<UINT>(width);
    desc.Height = static_cast<UINT>(height);
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;  // matches the RGBA ring
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
    desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    if (FAILED(d3d_->device->CreateTexture2D(&desc, nullptr,
                                             shared_texture_.GetAddressOf()))) {
      return false;
    }
    ComPtr<IDXGIResource> resource;
    if (FAILED(shared_texture_.As(&resource)) ||
        FAILED(resource->GetSharedHandle(&shared_handle_))) {
      shared_texture_.Reset();
      shared_handle_ = nullptr;
      return false;
    }
    width_ = width;
    height_ = height;
    return true;
  }

  flutter::TextureRegistrar* registrar_;
  D3dShared* d3d_;
  flutter::TextureVariant texture_;
  int64_t texture_id_ = 0;

  ComPtr<ID3D11Texture2D> shared_texture_;
  ComPtr<ID3D11Texture2D> retired_;
  HANDLE shared_handle_ = nullptr;  // borrowed from the resource; never closed
  int32_t width_ = 0;
  int32_t height_ = 0;

  std::mutex mutex_;  // guards descriptor_ / has_frame_
  FlutterDesktopGpuSurfaceDescriptor descriptor_ = {};
  // Only ever touched inside ObtainDescriptor (raster thread).
  FlutterDesktopGpuSurfaceDescriptor visible_descriptor_ = {};
  bool has_frame_ = false;
};

// CPU fallback: one Flutter pixel-buffer texture fed by the readback sink.
// The sink thread writes into `pending_`; the engine's raster thread swaps
// it into `visible_` inside CopyPixels — `visible_` is only ever touched
// there, so the returned pointer stays stable until the next CopyPixels.
class WinPixelBufferTexture : public PresentTextureBase {
 public:
  explicit WinPixelBufferTexture(flutter::TextureRegistrar* registrar)
      : registrar_(registrar),
        texture_(flutter::PixelBufferTexture(
            [this](size_t /*width*/, size_t /*height*/) {
              return CopyPixels();
            })) {
    texture_id_ = registrar_->RegisterTexture(&texture_);
  }

  int64_t texture_id() const override { return texture_id_; }

  void Publish(const uint8_t* pixels, int32_t width, int32_t height,
               int32_t bytes_per_row) override {
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

  void Unregister() override {
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
    ops.acquire_shared_handle = &OpsAcquireSharedHandle;
    ops.frame_presented = &OpsFramePresented;
    nwp_set_texture_ops(&ops);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit NitroWebgpuPlugin(flutter::TextureRegistrar* textures)
      : textures_(textures) {}

  ~NitroWebgpuPlugin() override { nwp_set_texture_ops(nullptr); }

  flutter::TextureRegistrar* textures() const { return textures_; }
  D3dShared* d3d() { return &d3d_; }

 private:
  static int64_t OpsRegisterTexture(void* ctx, void** out_handle) {
    auto* plugin = static_cast<NitroWebgpuPlugin*>(ctx);
    PresentTextureBase* texture;
    if (plugin->d3d()->Init()) {
      texture = new WinDxgiTexture(plugin->textures(), plugin->d3d());
    } else {
      texture = new WinPixelBufferTexture(plugin->textures());
    }
    *out_handle = texture;
    return texture->texture_id();
  }

  static void OpsPublishFrame(void* /*ctx*/, void* handle,
                              const uint8_t* pixels, int32_t width,
                              int32_t height, int32_t bytes_per_row) {
    static_cast<PresentTextureBase*>(handle)->Publish(pixels, width, height,
                                                      bytes_per_row);
  }

  static void OpsUnregisterTexture(void* /*ctx*/, void* handle) {
    static_cast<PresentTextureBase*>(handle)->Unregister();
  }

  static void* OpsAcquireSharedHandle(void* /*ctx*/, void* handle,
                                      int32_t width, int32_t height) {
    return static_cast<PresentTextureBase*>(handle)->AcquireSharedHandle(
        width, height);
  }

  static void OpsFramePresented(void* /*ctx*/, void* handle) {
    static_cast<PresentTextureBase*>(handle)->FramePresented();
  }

  flutter::TextureRegistrar* textures_;
  D3dShared d3d_;
};

}  // namespace

void NitroWebgpuPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  NitroWebgpuPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
