# Draft upstream issue — gfx-rs/wgpu-native

File with:

```bash
gh issue create --repo gfx-rs/wgpu-native \
  --title "Native handle accessors for D3D12 and Vulkan (mirroring the Metal trio)" \
  --body-file doc/upstream/wgpu-native-handle-accessors.md
```

(Delete this header block before filing; body starts below.)

---

## Feature request: D3D12 and Vulkan native handle accessors

v29 ships three Metal interop accessors in `ffi/wgpu.h`:

```c
void *wgpuDeviceGetNativeMetalDevice(WGPUDevice device);
void *wgpuQueueGetNativeMetalCommandQueue(WGPUQueue queue);
void *wgpuTextureGetNativeMetalTexture(WGPUTexture texture);
```

These make zero-copy presentation embeddings possible on Apple platforms: a
host compositor (in our case the Flutter engine) can blit a wgpu-rendered
texture GPU→GPU without the pixels ever touching the CPU.

There is no equivalent for the other native backends, so the same embedding
on Windows and Linux is forced through a full CPU readback
(`copyTextureToBuffer` → map → upload), even though both platforms have
first-class sharing primitives (DXGI shared handles / keyed mutexes on
D3D12, `VK_KHR_external_memory_fd` + dma-buf on Vulkan).

### Proposed API (same shape and ownership rules as the Metal trio)

```c
// D3D12 — borrowed pointers, valid while the wgpu object is alive,
// NULL when the active backend is not D3D12.
void *wgpuDeviceGetNativeD3D12Device(WGPUDevice device);       // ID3D12Device*
void *wgpuQueueGetNativeD3D12CommandQueue(WGPUQueue queue);    // ID3D12CommandQueue*
void *wgpuTextureGetNativeD3D12Resource(WGPUTexture texture);  // ID3D12Resource*

// Vulkan — handles are non-dispatchable u64s except the dispatchable
// device/instance; NULL/0 when the active backend is not Vulkan.
void *wgpuDeviceGetNativeVulkanDevice(WGPUDevice device);      // VkDevice
void *wgpuDeviceGetNativeVulkanPhysicalDevice(WGPUDevice device); // VkPhysicalDevice
uint64_t wgpuTextureGetNativeVulkanImage(WGPUTexture texture); // VkImage
```

Implementation should be mechanical alongside the Metal versions: they are
thin wrappers over `wgpu-core`'s `*_as_hal` APIs
(`Global::texture_as_hal::<hal::api::Dx12/Vulkan, _>`), exactly like
`wgpuTextureGetNativeMetalTexture` wraps the Metal variant today.

### Concrete use case

[nitro_webgpu](https://github.com/Shreemanarjun/nitro_webgpu) embeds wgpu in
Flutter on five platforms. Presentation today:

- **macOS/iOS**: zero-copy — Metal accessors → GPU blit into the compositor
  texture. Works great; this is the model.
- **Windows/Linux**: CPU readback per frame, because there is no way to
  reach the `ID3D12Resource`/`VkImage` behind a `WGPUTexture` from the C
  ABI. With `wgpuTextureGetNativeD3D12Resource` we would copy on-GPU into a
  `D3D11_RESOURCE_MISC_SHARED` interop texture (via a shared heap or
  11on12); with the Vulkan image we would export dma-buf and import into
  the compositor's GL/Vulkan context.

Happy to contribute the PR if the API shape is acceptable.
