package dev.shreeman.nitro_webgpu

import android.os.Handler
import android.os.Looper
import io.flutter.view.TextureRegistry
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import nitro.nitro_webgpu_present_module.HybridNitroWebgpuPresentSpec

/**
 * M2.3: Android presentation via `TextureRegistry.SurfaceProducer` — the
 * zero-copy path. The producer's Surface becomes a real `WGPUSurface`
 * (ANativeWindow → Vulkan/GLES swapchain) inside the shared present core;
 * acquire hands Dart the swapchain texture's view and present calls
 * `wgpuSurfacePresent`. No readback, no blit.
 *
 * Never caches `producer.surface` — it is re-fetched on every lifecycle
 * callback, per the SurfaceProducer contract.
 */
class NitroWebgpuPresentImpl(
    private val textureRegistry: TextureRegistry,
) : HybridNitroWebgpuPresentSpec {

    private class Entry(val producer: TextureRegistry.SurfaceProducer)

    private val native = NwpSurfacePresenter()
    private val entries = ConcurrentHashMap<Long, Entry>()
    private val mainHandler = Handler(Looper.getMainLooper())

    /// TextureRegistry methods are @UiThread; Nitro calls arrive on the Dart
    /// isolate thread (sync) or an async pool thread (suspend). Runs [block]
    /// on the Android main thread and waits for its result.
    private fun <T> onMain(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = CountDownLatch(1)
        var result: T? = null
        var error: Throwable? = null
        mainHandler.post {
            try {
                result = block()
            } catch (t: Throwable) {
                error = t
            }
            latch.countDown()
        }
        latch.await()
        error?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return result as T
    }

    override fun createPresenter(deviceAddress: Long, widthPx: Long, heightPx: Long): Long {
        // The whole setup runs as ONE main-thread block: surface lifecycle
        // callbacks are posted to the main looper, so nothing can fire
        // between adopting the Surface and registering the callback — the
        // cold-start "surface re-created before the callback existed" race
        // can't happen.
        val (producer, token) = onMain {
            val prod = textureRegistry.createSurfaceProducer()
            prod.setSize(widthPx.toInt(), heightPx.toInt())
            val t = native.nativeCreate(
                deviceAddress, prod.surface, widthPx.toInt(), heightPx.toInt())
            if (t == 0L) {
                prod.release()
            } else {
                // Re-fetch the Surface on every callback, per the
                // SurfaceProducer contract.
                prod.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                    override fun onSurfaceAvailable() {
                        native.nativeReplaceSurface(t, prod.surface)
                    }

                    override fun onSurfaceCleanup() {
                        native.nativeReplaceSurface(t, null)
                    }
                })
            }
            Pair(prod, t)
        }
        if (token == 0L) {
            throw IllegalStateException(
                "nitro_webgpu: failed to create a surface presenter " +
                    "(WGPUSurface creation/configure failed)")
        }
        entries[token] = Entry(producer)
        return token
    }

    override fun flutterTextureId(token: Long): Long =
        entries[token]?.producer?.id() ?: -1L

    override suspend fun acquireFrame(token: Long): Long =
        native.nativeAcquire(token)

    override fun presentFrame(token: Long) {
        native.nativePresent(token)
        entries[token]?.producer?.scheduleFrame()
    }

    override fun presenterFormat(token: Long): Long =
        native.nativeFormat(token).toLong()

    // The surface path is pure GPU — frames never touch the CPU.
    override fun presenterUsesGpuPath(token: Long): Boolean = true

    override fun resizePresenter(token: Long, widthPx: Long, heightPx: Long) {
        val entry = entries[token] ?: return
        mainHandler.post { entry.producer.setSize(widthPx.toInt(), heightPx.toInt()) }
        native.nativeResize(token, widthPx.toInt(), heightPx.toInt())
    }

    override suspend fun destroyPresenter(token: Long) {
        val entry = entries.remove(token) ?: return
        // Drain any in-flight work (surface mode presents synchronously, so
        // this returns immediately in practice; kept for parity with the
        // ring presenter's contract).
        var spins = 0
        while (native.nativeIsBusy(token) != 0 && spins++ < 500) {
            Thread.sleep(2)
        }
        native.nativeDestroy(token)
        mainHandler.post { entry.producer.release() }
    }
}
