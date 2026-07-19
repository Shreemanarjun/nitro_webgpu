// Native implementation of HybridNitroWebgpuPresentProtocol (iOS + macOS).
// Keep ios/Classes and macos/Classes copies of this file identical.
//
// Thin shim: all frame state and the wgpu side live in shared C++
// (src/present/present_core.cpp, exposed as the nwp_* C ABI). This file owns
// only the platform texture objects.
//
// Two presentation paths, chosen at createPresenter:
//  - Metal fast path (M2.1): wgpu's render target is blitted GPU→GPU into an
//    IOSurface-backed CVPixelBuffer from a pool (one blit, ~0.1–0.3 ms; no
//    CPU readback). Ordering: present core fires the GPU sink after
//    onSubmittedWorkDone, the blit runs on a shim-owned MTLCommandQueue, and
//    its completion handler calls nwp_presenter_frame_done.
//  - CPU readback fallback (M2.0): mapAsync → memcpy rows into a fresh
//    CVPixelBuffer. Used when Metal handles are unavailable.
import CoreVideo
import Foundation
import Metal
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif
#if canImport(NitroWebgpuCpp)
import NitroWebgpuCpp
#endif

/// Platform-side state of one presenter: the Flutter texture, the latest
/// presented CVPixelBuffer, and (fast path) the Metal blit machinery.
final class WebGpuPresenterEntry: NSObject, FlutterTexture {
    let token: Int64
    var textureId: Int64 = 0
    var usesGpuPath = false
    private let textures: FlutterTextureRegistry
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    // Metal fast path state.
    private var metalDevice: MTLDevice?
    private var blitQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolWidth: Int32 = 0
    private var poolHeight: Int32 = 0

    init(token: Int64, textures: FlutterTextureRegistry) {
        self.token = token
        self.textures = textures
    }

    /// Attempts to set up the GPU blit path. Returns false when the adapter
    /// is not running on Metal (readback fallback stays active).
    func setupMetal() -> Bool {
        guard let raw = nwp_presenter_metal_device(token) else { return false }
        guard let device =
            Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? MTLDevice
        else { return false }
        guard let queue = device.makeCommandQueue() else { return false }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil,
                                        &cache) == kCVReturnSuccess,
              let cache else { return false }
        metalDevice = device
        blitQueue = queue
        textureCache = cache
        return true
    }

    private func ensurePool(width: Int32, height: Int32) -> CVPixelBufferPool? {
        if let pool, poolWidth == width, poolHeight == height { return pool }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(width),
            kCVPixelBufferHeightKey: Int(height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3,
        ]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                      poolAttrs as CFDictionary,
                                      attrs as CFDictionary,
                                      &created) == kCVReturnSuccess else {
            return nil
        }
        pool = created
        poolWidth = width
        poolHeight = height
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        return created
    }

    /// GPU sink body — runs on a wgpu callback thread after the frame's
    /// submitted work completed. Blits the slot's wgpu target into a pool
    /// buffer; the blit's completion handler releases the slot back to the
    /// ring (other slots keep the pipeline full meanwhile).
    func gpuFrame(width: Int32, height: Int32,
                  metalTexture: UnsafeMutableRawPointer, slot: Int32) {
        let token = self.token
        let done = { nwp_presenter_frame_done(token, slot) }
        guard let blitQueue, let textureCache,
              let pool = ensurePool(width: width, height: height),
              let src = Unmanaged<AnyObject>.fromOpaque(metalTexture)
                  .takeUnretainedValue() as? MTLTexture
        else { return done() }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool,
                                                 &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return done() }

        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                  kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm,
                  Int(width), Int(height), 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture,
              let dst = CVMetalTextureGetTexture(cvTexture)
        else { return done() }

        guard let cmd = blitQueue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return done() }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: Int(width), height: Int(height),
                                      depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        let retainedCvTexture = cvTexture  // keep alive until GPU completes
        cmd.addCompletedHandler { [weak self] _ in
            _ = retainedCvTexture
            guard let self else { return done() }
            self.lock.lock()
            self.latest = buffer
            self.lock.unlock()
            done()
            let id = self.textureId
            let textures = self.textures
            DispatchQueue.main.async { textures.textureFrameAvailable(id) }
        }
        cmd.commit()
    }

    /// Readback sink body (fallback path) — runs on a wgpu callback thread
    /// while the readback buffer is mapped; copies rows into a fresh
    /// IOSurface-backed BGRA pixel buffer and signals Flutter.
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

    // ── Texture-import path (Dawn) ─────────────────────────────────────
    // The core imports our IOSurfaces and GPU-copies frames into them; we
    // only hand surfaces out and publish them once the core says the GPU
    // finished. Buffers stay retained in [inflight] between the two.
    private var inflight: [UnsafeRawPointer: CVPixelBuffer] = [:]

    func setupTextureImport() -> Bool {
        guard nwp_presenter_supports_texture_import(token) == 1 else {
            return false
        }
        let user = Unmanaged.passUnretained(self).toOpaque()
        nwp_presenter_set_import_ops(token, { _, width, height, user in
            guard let user else { return nil }
            let entry = Unmanaged<WebGpuPresenterEntry>.fromOpaque(user)
                .takeUnretainedValue()
            return entry.acquireIOSurface(width: width, height: height)
        }, { _, surface, user in
            guard let user, let surface else { return }
            let entry = Unmanaged<WebGpuPresenterEntry>.fromOpaque(user)
                .takeUnretainedValue()
            entry.importedFramePresented(UnsafeRawPointer(surface))
        }, user)
        return true
    }

    private func acquireIOSurface(width: Int32,
                                  height: Int32) -> UnsafeMutableRawPointer? {
        guard let pool = ensurePool(width: width, height: height) else {
            return nil
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool,
                                                 &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer,
              let surface = CVPixelBufferGetIOSurface(buffer)?
                  .takeUnretainedValue()
        else { return nil }
        let key = UnsafeRawPointer(Unmanaged.passUnretained(surface).toOpaque())
        lock.lock()
        inflight[key] = buffer
        lock.unlock()
        return UnsafeMutableRawPointer(mutating: key)
    }

    private func importedFramePresented(_ surface: UnsafeRawPointer) {
        lock.lock()
        let buffer = inflight.removeValue(forKey: surface)
        if let buffer { latest = buffer }
        lock.unlock()
        guard buffer != nil else { return }
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
        // passUnretained is safe for the sinks' lifetime.
        let user = Unmanaged.passUnretained(entry).toOpaque()
        let usingMetal = entry.setupMetal()
        let usingImport = usingMetal ? false : entry.setupTextureImport()
        entry.usesGpuPath = usingMetal || usingImport
        NSLog("nitro_webgpu: presenter %lld using %@ path", token,
              usingMetal ? "Metal blit"
                         : usingImport ? "texture import" : "CPU readback")
        if usingImport {
            // Ops were installed by setupTextureImport; the core drives the
            // whole frame (import → GPU copy → presented callback).
        } else if usingMetal {
            nwp_presenter_set_gpu_sink(token, { token, width, height, mtl, slot, user in
                guard let user else { return }
                guard let mtl else {
                    nwp_presenter_frame_done(token, slot)
                    return
                }
                let entry = Unmanaged<WebGpuPresenterEntry>.fromOpaque(user)
                    .takeUnretainedValue()
                entry.gpuFrame(width: width, height: height,
                               metalTexture: mtl, slot: slot)
            }, user)
        } else {
            nwp_presenter_set_sink(token, { _, pixels, width, height, bpr, user in
                guard let user, let pixels else { return }
                let entry = Unmanaged<WebGpuPresenterEntry>.fromOpaque(user)
                    .takeUnretainedValue()
                entry.consume(pixels: pixels, width: width, height: height,
                              bytesPerRow: bpr)
            }, user)
        }
        return token
    }

    public func flutterTextureId(token: Int64) -> Int64 {
        return entry(token)?.textureId ?? 0
    }

    public func acquireFrame(token: Int64) async throws -> Int64 {
        return nwp_presenter_acquire(token)
    }

    public func acquireFrameSync(token: Int64) -> Int64 {
        // Lock-free ring acquire — safe on the calling (Dart) thread.
        return nwp_presenter_acquire(token)
    }

    public func presentFrame(token: Int64) {
        nwp_presenter_present(token)
    }

    public func presenterFormat(token: Int64) -> Int64 {
        return Int64(nwp_presenter_format(token))
    }

    public func presenterUsesGpuPath(token: Int64) -> Bool {
        return entry(token)?.usesGpuPath ?? false
    }

    public func requestMaxRefreshRate() -> Double {
        // Apple platforms drive refresh through the display link (ProMotion
        // adapts automatically); nothing to request here.
        return 0
    }

    public func presenterSetSurfaceSize(token: Int64, widthPx: Int64, heightPx: Int64) {
        // Ring presenters render offscreen — there is no window surface to
        // resize; the render size (resizePresenter) is the only dimension.
    }

    public func resizePresenter(token: Int64, widthPx: Int64, heightPx: Int64) {
        nwp_presenter_resize(token, Int32(widthPx), Int32(heightPx))
    }

    public func destroyPresenter(token: Int64) async throws {
        // Drain the in-flight present before unregistering the texture
        // (bounded; the core defers its own teardown safely if still busy).
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
