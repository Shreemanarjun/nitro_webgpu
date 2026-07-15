import Flutter

/// All nitro_webgpu modules are NativeImpl.cpp — the C++ implementation
/// self-registers when the library loads, so no Swift registration is needed.
/// This class exists to satisfy the `pluginClass` entry in pubspec.yaml and
/// will host the Flutter texture-registry handoff for presentation (M2).
public class SwiftNitroWebgpuPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        NitroWebgpuPresentRegistry.register(NitroWebgpuPresentModuleImpl())}
}
