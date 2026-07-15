package dev.shreeman.nitro_webgpu

import nitro.nitro_webgpu_present_module.HybridNitroWebgpuPresentSpec

/**
 * M2.0 STUB: Android presentation lands in M2.3 (SurfaceProducer → real
 * WGPUSurface, zero copy). The core nitro_webgpu module works on Android;
 * only rendering into a Flutter widget is not wired yet.
 */
class NitroWebgpuPresentImpl : HybridNitroWebgpuPresentSpec {
    private val notSupported =
        "WebGPU presentation is not implemented on Android yet (M2.3)"

    override fun createPresenter(deviceAddress: Long, widthPx: Long, heightPx: Long): Long =
        throw UnsupportedOperationException(notSupported)

    override fun flutterTextureId(token: Long): Long =
        throw UnsupportedOperationException(notSupported)

    override suspend fun acquireFrame(token: Long): Long =
        throw UnsupportedOperationException(notSupported)

    override fun presentFrame(token: Long): Unit =
        throw UnsupportedOperationException(notSupported)

    override fun presenterFormat(token: Long): Long =
        throw UnsupportedOperationException(notSupported)

    override fun presenterUsesGpuPath(token: Long): Boolean =
        throw UnsupportedOperationException(notSupported)

    override fun resizePresenter(token: Long, widthPx: Long, heightPx: Long): Unit =
        throw UnsupportedOperationException(notSupported)

    override suspend fun destroyPresenter(token: Long): Unit =
        throw UnsupportedOperationException(notSupported)
}
