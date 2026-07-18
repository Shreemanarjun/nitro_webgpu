package dev.shreeman.nitro_webgpu

import android.view.Surface

/**
 * JNI bindings into the shared present core (surface mode). Implemented in
 * `src/present/nwp_android_jni.cpp`, compiled into libnitro_webgpu.so —
 * which the plugin loads before any instance of this class exists.
 */
internal class NwpSurfacePresenter {
    external fun nativeCreate(
        deviceAddress: Long, surface: Surface, width: Int, height: Int): Long

    external fun nativeReplaceSurface(
        token: Long, surface: Surface?, width: Int, height: Int)
    external fun nativeAcquire(token: Long): Long
    external fun nativePresent(token: Long)
    external fun nativeFormat(token: Long): Int
    external fun nativeResize(token: Long, width: Int, height: Int)
    external fun nativeIsBusy(token: Long): Int
    external fun nativeIsSurfaceMode(token: Long): Int
    external fun nativeDestroy(token: Long)
}
