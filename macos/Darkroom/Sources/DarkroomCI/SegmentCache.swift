// Method: render a stack segment's result once into a texture the engine owns, and start the next render from that
// texture when everything that produced it is unchanged (the downstream-only recompute the oracle's StageGraph proves in
// chart test T4; the segment boundaries and the half-float intermediates follow Apple's Core Image performance guidance,
// WWDC20 10008 "Optimize the Core Image pipeline for your video app").
//
// Why it exists: Core Image's own `cacheIntermediates` reuses a node's result across renders only some of the time. Measured
// with `dtb-selftest --viewport-bench`, a display-contrast drag with four neighbourhood modules on took 5 ms at 1600 px and
// 9 ms at 2300 px but 125 to 145 ms at 2200 and 2400 px: a cliff that depends on the frame's size. This cache does not depend
// on the size. A key is the full text of everything that decides the pixels, so a stale picture cannot be served; a miss is
// only slowness.

import CoreImage
import Foundation
import Metal

final class SegmentCache: @unchecked Sendable {
    private struct Entry {
        let texture: MTLTexture
        let origin: CGPoint
        var stamp: Int
        var bytes: Int { texture.width * texture.height * 8 }
    }

    private let context: CIContext
    private let device: MTLDevice
    private let space: CGColorSpace
    private let budget: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var clock = 0
    private(set) var hits = 0
    private(set) var misses = 0

    /// `space` is the context's working space (the textures hold values in it, linear and unclamped).
    init(context: CIContext, device: MTLDevice, space: CGColorSpace, budgetBytes: Int = 768 << 20) {
        self.context = context; self.device = device; self.space = space; self.budget = budgetBytes
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// The cached image for `key`, if there is one.
    func lookup(_ key: String) -> CIImage? {
        lock.lock()
        guard var e = entries[key] else { misses += 1; lock.unlock(); return nil }
        clock += 1; e.stamp = clock; entries[key] = e; hits += 1
        lock.unlock()
        return image(of: e)
    }

    /// Renders `image` into a texture kept under `key` and returns an image that reads from it. When the render fails the
    /// original image comes back, so the edit still works, only without the speed-up.
    func store(_ image: CIImage, key: String) -> CIImage {
        let rect = image.extent.integral
        guard rect.width >= 1, rect.height >= 1, rect.width < 16384, rect.height < 16384, image.extent.isInfinite == false else { return image }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Int(rect.width), height: Int(rect.height), mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc) else { return image }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = space
        guard let task = try? context.startTask(toRender: image, from: rect, to: destination, at: .zero),
              (try? task.waitUntilCompleted()) != nil else { return image }
        let entry: Entry
        lock.lock()
        clock += 1
        entry = Entry(texture: texture, origin: rect.origin, stamp: clock)
        entries[key] = entry
        var total = entries.values.reduce(0) { $0 + $1.bytes }
        while total > budget, entries.count > 1, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp }), oldest.key != key {
            total -= oldest.value.bytes
            entries[oldest.key] = nil
        }
        lock.unlock()
        return self.image(of: entry)
    }

    private func image(of e: Entry) -> CIImage {
        // CIRenderDestination and CIImage(mtlTexture:) apply the same top-left/bottom-left flip, so the round trip is upright with no fix-up
        // (a stored boundary that came back flipped went unseen while a stack had two of them, which cancel: E-SEG now covers one to three)
        let img = CIImage(mtlTexture: e.texture, options: [.colorSpace: space]) ?? CIImage.empty()
        return img.transformed(by: CGAffineTransform(translationX: e.origin.x, y: e.origin.y))
    }
}
