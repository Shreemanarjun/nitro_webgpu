import Flutter

/// The core nitro_webgpu module is NativeImpl.cpp and self-registers when the
/// library loads. This class registers the presentation module's Swift impl,
/// handing it the Flutter texture registry.
public class SwiftNitroWebgpuPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        NitroWebgpuPresentRegistry.register(
            NitroWebgpuPresentModuleImpl(textures: registrar.textures()))
    }
}
