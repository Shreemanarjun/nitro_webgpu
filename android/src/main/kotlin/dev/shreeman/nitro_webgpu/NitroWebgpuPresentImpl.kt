package dev.shreeman.nitro_webgpu

import android.os.Build
import android.view.Surface
import android.os.Handler
import android.os.Looper
import android.os.PerformanceHintManager
import android.os.Process
import android.os.SystemClock
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

    private class Entry(
        val producer: TextureRegistry.SurfaceProducer,
        var surfaceW: Int,
        var surfaceH: Int,
    )

    private val native = NwpSurfacePresenter()
    private val entries = ConcurrentHashMap<Long, Entry>()
    private val mainHandler = Handler(Looper.getMainLooper())

    // ADPF: tells the OS governor our frame cadence so clocks stay boosted
    // instead of decaying mid-session (the classic "starts fast, degrades"
    // pattern). Created lazily on the render (Dart) thread so the session
    // covers the thread doing the actual per-frame work.
    private var hintSession: PerformanceHintManager.Session? = null
    private var hintTargetNs = 0L
    private var lastFrameNs = 0L

    private fun reportFrameToAdpf() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val now = SystemClock.elapsedRealtimeNanos()
        if (hintSession == null) {
            val mgr = applicationContext
                .getSystemService(PerformanceHintManager::class.java) ?: return
            val display = activity?.display
            val hz = display?.refreshRate ?: 60f
            hintTargetNs = (1e9 / hz).toLong()
            hintSession = mgr.createHintSession(
                intArrayOf(Process.myTid()), hintTargetNs)
            lastFrameNs = now
            return
        }
        val dur = now - lastFrameNs
        lastFrameNs = now
        if (dur in 1..(hintTargetNs * 4)) {
            hintSession?.reportActualWorkDuration(dur)
        }
    }

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
            val surface = prod.surface
            requestSurfaceFrameRate(surface)
            val t = native.nativeCreate(
                deviceAddress, surface, widthPx.toInt(), heightPx.toInt())
            if (t == 0L) {
                prod.release()
            } else {
                // Re-fetch the Surface on every callback, per the
                // SurfaceProducer contract.
                prod.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                    override fun onSurfaceAvailable() {
                        // 0×0 keeps the current surface size.
                        val s = prod.surface
                        requestSurfaceFrameRate(s)
                        native.nativeReplaceSurface(t, s, 0, 0)
                    }

                    override fun onSurfaceCleanup() {
                        native.nativeReplaceSurface(t, null, 0, 0)
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
        entries[token] = Entry(producer, widthPx.toInt(), heightPx.toInt())
        return token
    }

    override fun flutterTextureId(token: Long): Long =
        entries[token]?.producer?.id() ?: -1L

    override suspend fun acquireFrame(token: Long): Long =
        native.nativeAcquire(token)

    override fun acquireFrameSync(token: Long): Long =
        native.nativeAcquire(token)

    override fun presentFrame(token: Long) {
        native.nativePresent(token)
        entries[token]?.producer?.scheduleFrame()
        reportFrameToAdpf()
    }

    override fun presenterFormat(token: Long): Long =
        native.nativeFormat(token).toLong()

    // The surface path is pure GPU — frames never touch the CPU.
    override fun presenterUsesGpuPath(token: Long): Boolean = true

    override fun resizePresenter(token: Long, widthPx: Long, heightPx: Long) {
        // Render-resolution only: the swapchain and SurfaceProducer stay
        // untouched — frames render into an internal scaled target and are
        // blit-upscaled at present, so this never flickers.
        native.nativeResize(token, widthPx.toInt(), heightPx.toInt())
    }

    override fun presenterSetSurfaceSize(token: Long, widthPx: Long, heightPx: Long) {
        val entry = entries[token] ?: return
        val w = widthPx.toInt()
        val h = heightPx.toInt()
        if (entry.surfaceW == w && entry.surfaceH == h) return
        entry.surfaceW = w
        entry.surfaceH = h
        onMain {
            // setSize hands out a NEW Surface on the next getSurface() —
            // re-fetch and rebuild the swapchain against it.
            entry.producer.setSize(w, h)
            val s = entry.producer.surface
            requestSurfaceFrameRate(s)
            native.nativeReplaceSurface(token, s, w, h)
        }
    }

    // The display's fastest rate, remembered so every adopted Surface can
    // re-assert it (vendor "game" governors override the window mode; an
    // explicit per-surface setFrameRate is the strongest app-side signal).
    private var targetFrameRate = 0f

    private fun requestSurfaceFrameRate(surface: Surface) {
        if (targetFrameRate <= 0f) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            surface.setFrameRate(
                targetFrameRate,
                Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                Surface.CHANGE_FRAME_RATE_ALWAYS,
            )
        }
    }

    override fun requestMaxRefreshRate(): Double {
        val act = activity ?: return 0.0
        return onMain {
            val display = act.display ?: return@onMain 0.0
            val best = display.supportedModes
                .filter {
                    it.physicalWidth == display.mode.physicalWidth &&
                        it.physicalHeight == display.mode.physicalHeight
                }
                .maxByOrNull { it.refreshRate } ?: return@onMain 0.0
            val attrs = act.window.attributes
            attrs.preferredDisplayModeId = best.modeId
            // Legacy float hint — some vendor refresh-rate governors only
            // honor this one.
            attrs.preferredRefreshRate = best.refreshRate
            act.window.attributes = attrs
            targetFrameRate = best.refreshRate
            best.refreshRate.toDouble()
        }
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
