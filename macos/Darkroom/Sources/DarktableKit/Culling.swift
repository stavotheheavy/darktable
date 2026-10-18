import CoreGraphics
import Foundation

/// Classical culling helpers: no model, no network, nothing leaves the Mac. They work on
/// small copies of the frame, so scoring a card of photos takes seconds.
public enum Culling {
    /// 8 bit grey pixels of the image scaled to fit `side` on its long edge.
    static func grey(_ image: CGImage, fitting side: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        let scale = min(1, Double(side) / Double(max(image.width, image.height)))
        let w = max(8, Int((Double(image.width) * scale).rounded()))
        let h = max(8, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (pixels, w, h) : nil
    }

    /// How much edge detail the frame has, 0 to 100. It is the variance of the Laplacian on a
    /// 384 pixel copy, on a log scale. The number means something only against other frames
    /// from the same shoot: a soft frame scores clearly lower than the sharp one next to it.
    public static func sharpness(of image: CGImage) -> Double {
        guard let (p, w, h) = grey(image, fitting: 384), w > 2, h > 2 else { return 0 }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = 4 * Double(p[i]) - Double(p[i - 1]) - Double(p[i + 1]) - Double(p[i - w]) - Double(p[i + w])
                sum += lap; sumSq += lap * lap; n += 1
            }
        }
        let mean = sum / n
        let variance = sumSq / n - mean * mean
        return min(100, max(0, 11 * log2(1 + variance / 2)))
    }

    /// A 64 bit average hash: the frame shrunk to 8 by 8 grey, one bit per cell above the mean.
    public static func averageHash(of image: CGImage) -> UInt64 {
        let small = squash(image)
        let mean = small.reduce(0) { $0 + Int($1) } / max(1, small.count)
        var h: UInt64 = 0
        for (i, v) in small.prefix(64).enumerated() where Int(v) >= mean { h |= 1 << UInt64(i) }
        return h
    }

    private static func squash(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 64)
        pixels.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            }
        }
        return pixels
    }

    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Groups near-duplicates: frames shot within `maxGap` seconds of the one before that
    /// also look alike. Returns a group number per frame, nil for frames that stand alone.
    /// Frames are taken in capture order; the result is indexed like the input.
    public static func stacks(dates: [Date?], hashes: [UInt64?], maxGap: TimeInterval = 8,
                              maxDistance: Int = 16) -> [Int?] {
        precondition(dates.count == hashes.count)
        let order = dates.indices.sorted { (dates[$0] ?? .distantPast) < (dates[$1] ?? .distantPast) }
        var out = [Int?](repeating: nil, count: dates.count)
        var groups: [[Int]] = []
        var current: [Int] = []
        func flush() { if current.count > 1 { groups.append(current) }; current = [] }
        for i in order {
            guard let d = dates[i], let h = hashes[i] else { flush(); continue }
            if let last = current.last, let ld = dates[last], let lh = hashes[last],
               d.timeIntervalSince(ld) <= maxGap, distance(h, lh) <= maxDistance {
                current.append(i)
            } else {
                flush()
                current = [i]
            }
        }
        flush()
        for (g, members) in groups.enumerated() { for i in members { out[i] = g } }
        return out
    }
}
