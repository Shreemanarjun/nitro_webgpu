// Android JNI shim for the surface-mode presenter (M2.3).
//
// Kotlin (NwpSurfacePresenter) drives the shared present core through these
// externals. Compiled into the core nitro_webgpu library (Android only) so
// it can reach the nwp_* C ABI and wgpu-native directly; the Kotlin side
// owns only the Flutter SurfaceProducer.
#include <jni.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include "present_core.h"

extern "C" {

JNIEXPORT jlong JNICALL
Java_dev_shreeman_nitro_1webgpu_NwpSurfacePresenter_nativeCreate(
    JNIEnv* env, jobject, jlong deviceAddress, jobject surface, jint width,
    jint height) {
    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    if (!window) return 0;
    const int64_t token =
        nwp_presenter_create_surface(deviceAddress, window, width, height);
    if (!token) ANativeWindow_release(window);
    return token;
}

JNIEXPORT void JNICALL
Java_dev_shreeman_nitro_1webgpu_NwpSurfacePresenter_nativeReplaceSurface(
    JNIEnv* env, jobject, jlong token, jobject surface, jint width,
    jint height) {
    ANativeWindow* window =
        surface ? ANativeWindow_fromSurface(env, surface) : nullptr;
    nwp_presenter_replace_surface(token, window, width, height);
    // On failure the core released nothing; the window ref is owned by the
    // presenter on success. nwp_presenter_replace_surface never partially
    // adopts, so nothing to clean up here.
}

JNIEXPORT jlong JNICALL
Java_dev_shreeman_nitro_1webgpu_NwpSurfacePresenter_nativeAcquire(
    JNIEnv*, jobject, jlong token) {
    return nwp_presenter_acquire(token);
}

JNIEXPORT void JNICALL
Java_dev_shreeman_nitro_1webgpu_NwpSurfacePresenter_nativePresent(
    JNIEnv*, jobject, jlong token) {
    nwp_presenter_present(token);
}

JNIEXPORT jint JNICALL
Java_dev_shreeman_nitro_1webgpu_NwpSurfacePresenter_nativeFormat(
    JNIEnv*, jobject, jlong token) {
    return nwp_presenter_format(token);
}

JNIEXPORT void JNICALL
Java_dev_shreeman_nitro_1webgpu_NwpSurfacePresenter_nativeResize(
    JNIEnv*, jobject, jlong token, jint width, jint height) {
    nwp_presenter_resize(token, width, height);
}

JNIEXPORT jint JNICALL
Java_dev_shreeman_nitro_1webgpu_NwpSurfacePresenter_nativeIsBusy(
    JNIEnv*, jobject, jlong token) {
    return nwp_presenter_is_busy(token);
}

JNIEXPORT void JNICALL
Java_dev_shreeman_nitro_1webgpu_NwpSurfacePresenter_nativeDestroy(
    JNIEnv*, jobject, jlong token) {
    nwp_presenter_destroy(token);
}

}  // extern "C"
