package dev.shreeman.nitro_webgpu

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import nitro.nitro_webgpu_module.NitroWebgpuJniBridge
import nitro.nitro_webgpu_present_module.NitroWebgpuPresentJniBridge

class NitroWebgpuPlugin : FlutterPlugin, ActivityAware {

    companion object {
        init {
            System.loadLibrary("nitro_webgpu")
            System.loadLibrary("nitro_webgpu_present")
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // The core module's impl is all-C++ (registered when the library
        // loads); only the present module has a Kotlin implementation. The
        // factory captures the engine's texture registry — one presenter
        // impl per Dart-side instance.
        NitroWebgpuPresentJniBridge.registerFactory(
            { NitroWebgpuPresentImpl(binding.textureRegistry) },
            binding.applicationContext,
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        NitroWebgpuJniBridge.onActivityAttached(binding.activity)
        NitroWebgpuPresentJniBridge.onActivityAttached(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        NitroWebgpuJniBridge.onActivityDetached()
        NitroWebgpuPresentJniBridge.onActivityDetached()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        NitroWebgpuJniBridge.onActivityAttached(binding.activity)
        NitroWebgpuPresentJniBridge.onActivityAttached(binding.activity)
    }

    override fun onDetachedFromActivity() {
        NitroWebgpuJniBridge.onActivityDetached()
        NitroWebgpuPresentJniBridge.onActivityDetached()
    }
}
