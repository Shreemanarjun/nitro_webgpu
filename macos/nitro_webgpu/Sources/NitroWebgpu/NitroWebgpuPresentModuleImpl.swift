// Native implementation of HybridNitroWebgpuPresentProtocol (iOS + macOS).
// Keep ios/Classes and macos/Classes copies of this file identical.
//
// Thin shim: all frame state and the wgpu readback path live in shared C++
// (src/present/present_core.cpp, exposed as the nwp_* C ABI). This file owns
// only the platform texture objects — a CVPixelBuffer handed to Flutter's
// texture registry.
import CoreVideo
import Foundation
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif
#if canImport(NitroWebgpuCpp)
import NitroWebgpuCpp
#endif

/// Platform-side state of one presenter: the Flutter texture and the latest
/// presented CVPixelBuffer.
final class WebGpuPresenterEntry: NSObject, FlutterTexture {
    let token: Int64
    var textureId: Int64 = 0
    private let textures: FlutterTextureRegistry
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    init(token: Int64, textures: FlutterTextureRegistry) {
        self.token = token
        self.textures = textures
    }

    /// Sink callback body — runs on a wgpu callback thread while the readback
    /// buffer is mapped; copies rows into a fresh IOSurface-backed BGRA
    /// pixel buffer and signals Flutter on the main thread.
    func consume(pixels: UnsafePointer<UInt8>, width: Int32, height: Int32,
                 bytesPerRow: Int32) {
        var created: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(width), Int(height),
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary,
                                  &created) == kCVReturnSuccess,
              let buffer = created else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let dst = CVPixelBufferGetBaseAddress(buffer) {
            let dstBpr = CVPixelBufferGetBytesPerRow(buffer)
            let copyBpr = min(Int(bytesPerRow), dstBpr)
            for row in 0..<Int(height) {
                memcpy(dst + row * dstBpr,
                       pixels + row * Int(bytesPerRow), copyBpr)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        lock.lock()
        latest = buffer
        lock.unlock()
        let id = textureId
        let textures = self.textures
        DispatchQueue.main.async { textures.textureFrameAvailable(id) }
    }

    public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest else { return nil }
        return Unmanaged.passRetained(latest)
    }
}

public class NitroWebgpuPresentModuleImpl: NSObject,
    HybridNitroWebgpuPresentProtocol {
    private let textures: FlutterTextureRegistry
    private var entries: [Int64: WebGpuPresenterEntry] = [:]
    private let lock = NSLock()

    public init(textures: FlutterTextureRegistry) {
        self.textures = textures
    }

    private func entry(_ token: Int64) -> WebGpuPresenterEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[token]
    }

    public func createPresenter(deviceAddress: Int64, widthPx: Int64,
                                heightPx: Int64) -> Int64 {
        let token =
            nwp_presenter_create(deviceAddress, Int32(widthPx), Int32(heightPx))
        guard token != 0 else { return 0 }
        let entry = WebGpuPresenterEntry(token: token, textures: textures)
        entry.textureId = textures.register(entry)
        lock.lock()
        entries[token] = entry
        lock.unlock()
        // The entry stays retained in `entries` until destroyPresenter, so
        // passUnretained is safe for the sink's lifetime.
        nwp_presenter_set_sink(token, { token, pixels, width, height, bpr, user in
            guard let user, let pixels else { return }
            let entry =
                Unmanaged<WebGpuPresenterEntry>.fromOpaque(user).takeUnretainedValue()
            entry.consume(pixels: pixels, width: width, height: height,
                          bytesPerRow: bpr)
        }, Unmanaged.passUnretained(entry).toOpaque())
        return token
    }

    public func flutterTextureId(token: Int64) -> Int64 {
        return entry(token)?.textureId ?? 0
    }

    public func acquireFrame(token: Int64) async throws -> Int64 {
        return nwp_presenter_acquire(token)
    }

    public func presentFrame(token: Int64) {
        nwp_presenter_present(token)
    }

    public func presenterFormat(token: Int64) -> Int64 {
        return Int64(nwp_presenter_format(token))
    }

    public func resizePresenter(token: Int64, widthPx: Int64, heightPx: Int64) {
        nwp_presenter_resize(token, Int32(widthPx), Int32(heightPx))
    }

    public func destroyPresenter(token: Int64) async throws {
        // Drain the in-flight readback before tearing down wgpu objects
        // (bounded: ~1s worst case, then tear down regardless).
        var attempts = 0
        while nwp_presenter_is_busy(token) == 1 && attempts < 500 {
            try await Task.sleep(nanoseconds: 2_000_000)
            attempts += 1
        }
        nwp_presenter_destroy(token)
        lock.lock()
        let removed = entries.removeValue(forKey: token)
        lock.unlock()
        if let removed {
            let id = removed.textureId
            let textures = self.textures
            await MainActor.run { textures.unregisterTexture(id) }
        }
    }
}
