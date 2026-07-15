import Foundation

/// Native implementation of HybridNitroWebgpuProtocol on macOS.
public class NitroWebgpuImpl: NSObject, HybridNitroWebgpuProtocol {

    public func add(a: Double, b: Double) -> Double {
        return a + b
    }

    public func getGreeting(name: String) async throws -> String {
        return "Hello, \(name) from macOS!"
    }
}
