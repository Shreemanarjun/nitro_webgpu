// Standalone CI probe: repeated fallback-adapter + device acquire/release
// cycles on one WGPUInstance — the exact pattern the integration suite runs
// before wgpuInstanceRequestAdapter starts panicking on lavapipe (CI Linux,
// core-dump verified). Running it outside Flutter keeps wgpu's panic message
// on a visible stderr.
//
// Build (from the repo root, after fetch_wgpu_native.sh):
//   cc scripts/ci/adapter_cycle_probe.c \
//      src/third_party/wgpu_native/linux-x86_64/lib/libwgpu_native.a \
//      -Isrc/third_party/wgpu_native/include -lm -ldl -lpthread \
//      -o /tmp/adapter_cycle_probe
#include <stdio.h>
#include <webgpu/webgpu.h>

static WGPUAdapter g_adapter;
static WGPUDevice g_device;

static void onAdapter(WGPURequestAdapterStatus status, WGPUAdapter adapter,
                      WGPUStringView message, void* u1, void* u2) {
    (void)u1; (void)u2;
    if (status != WGPURequestAdapterStatus_Success) {
        fprintf(stderr, "adapter error: %.*s\n", (int)message.length,
                message.data ? message.data : "");
    }
    g_adapter = adapter;
}

static void onDevice(WGPURequestDeviceStatus status, WGPUDevice device,
                     WGPUStringView message, void* u1, void* u2) {
    (void)u1; (void)u2;
    if (status != WGPURequestDeviceStatus_Success) {
        fprintf(stderr, "device error: %.*s\n", (int)message.length,
                message.data ? message.data : "");
    }
    g_device = device;
}

int main(void) {
    WGPUInstance instance = wgpuCreateInstance(NULL);
    if (!instance) {
        fprintf(stderr, "wgpuCreateInstance failed\n");
        return 1;
    }
    for (int i = 0; i < 40; i++) {
        g_adapter = NULL;
        g_device = NULL;

        WGPURequestAdapterOptions opts = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
        opts.forceFallbackAdapter = 1;
        WGPURequestAdapterCallbackInfo acb =
            WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
        acb.mode = WGPUCallbackMode_AllowProcessEvents;
        acb.callback = onAdapter;
        wgpuInstanceRequestAdapter(instance, &opts, acb);
        for (int t = 0; t < 1000 && !g_adapter; t++) {
            wgpuInstanceProcessEvents(instance);
        }
        if (!g_adapter) {
            fprintf(stderr, "iter %d: no adapter\n", i);
            return 1;
        }

        WGPUDeviceDescriptor dd = WGPU_DEVICE_DESCRIPTOR_INIT;
        WGPURequestDeviceCallbackInfo dcb =
            WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
        dcb.mode = WGPUCallbackMode_AllowProcessEvents;
        dcb.callback = onDevice;
        wgpuAdapterRequestDevice(g_adapter, &dd, dcb);
        for (int t = 0; t < 1000 && !g_device; t++) {
            wgpuInstanceProcessEvents(instance);
        }
        if (!g_device) {
            fprintf(stderr, "iter %d: no device\n", i);
            return 1;
        }

        WGPUQueue queue = wgpuDeviceGetQueue(g_device);
        wgpuQueueRelease(queue);
        wgpuDeviceRelease(g_device);
        wgpuAdapterRelease(g_adapter);
        fprintf(stderr, "iter %d ok\n", i);
    }
    fprintf(stderr, "PROBE PASSED: 40 adapter+device cycles\n");
    return 0;
}
