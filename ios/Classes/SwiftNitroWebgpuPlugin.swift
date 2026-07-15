import Flutter
import UIKit

public class SwiftNitroWebgpuPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        NitroWebgpuRegistry.register(NitroWebgpuImpl())
    }
}
