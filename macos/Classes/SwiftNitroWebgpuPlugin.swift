import FlutterMacOS
import AppKit

public class SwiftNitroWebgpuPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        NitroWebgpuRegistry.register(NitroWebgpuImpl())
    }
}
