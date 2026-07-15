package dev.shreeman.nitro_webgpu

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

class NitroWebgpuPlugin : FlutterPlugin, ActivityAware {

    companion object {
        init { System.loadLibrary("nitro_webgpu") }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // registerFactory: one impl per Dart-side instance (multi-instance
        // registry). The old single-instance register(impl, context) API no
        // longer exists on the generated JniBridge.
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NitroWebgpuJniBridge.onDetached()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        NitroWebgpuJniBridge.onActivityAttached(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        NitroWebgpuJniBridge.onActivityDetached()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        NitroWebgpuJniBridge.onActivityAttached(binding.activity)
    }

    override fun onDetachedFromActivity() {
        NitroWebgpuJniBridge.onActivityDetached()
    }
}