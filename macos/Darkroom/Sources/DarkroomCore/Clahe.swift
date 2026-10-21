// Method: contrast limited adaptive histogram equalisation (K. Zuiderveld, "Contrast Limited Adaptive Histogram Equalization", Graphics Gems IV, 1994). The frame is cut into a grid of
// tiles (`tiles` across; the count down keeps them near square); for each tile the histogram of the display-encoded luminance (the sRGB transfer curve of IEC 61966-2-1) is taken in 256 bins,
// every bin is clipped at `clip` times the average bin count and the clipped excess is spread evenly over all bins (which bounds the contrast gain and so the noise amplification), and
// the cumulative sum, scaled to 0...1, is the tile's mapping. A pixel is mapped by bilinear interpolation of the four nearest tile centres' mappings of its own bin, so there are no
// tile seams. The new luminance is given back as a gain on all three channels (colour ratios kept); pixels past white (luminance above 1) or at black are left alone. The result is mixed
// in by `amount` (0 is the identity).
//
// Tile membership is integer: pixel x is in tile floor(x tiles / width), so the tile bounds are the ceilings of k width / tiles.

import Foundation

public enum Clahe {
    public static let bins = 256

    /// The grid for a frame: `tiles` across, and as many down as keeps tiles near square (at least 1).
    public static func grid(tiles: Int, width: Int, height: Int) -> (x: Int, y: Int) {
        let tx = max(tiles, 1)
        return (tx, max(Int((Double(tx) * Double(height) / Double(max(width, 1))).rounded()), 1))
    }

    static func encodedLuma(_ v: SIMD3<Double>) -> (y: Double, e: Double) {
        let y = ColorCommon.luminance(v)
        return (y, y.isNaN ? 0 : Transfer.linearToSRGB(min(max(y, 0), 1)))
    }

    /// The mappings, tile by tile (row-major), 256 values each.
    public static func luts(_ rgb: [SIMD3<Double>], width: Int, height: Int, tiles: Int, clip: Double) -> [[Double]] {
        let g = grid(tiles: tiles, width: width, height: height)
        var counts = [[Int]](repeating: [Int](repeating: 0, count: bins), count: g.x * g.y)
        for y in 0..<height {
            for x in 0..<width {
                let tile = (y * g.y / height) * g.x + x * g.x / width
                let bin = min(bins - 1, Int((encodedLuma(rgb[y * width + x]).e * Double(bins)).rounded(.down)))
                counts[tile][bin] += 1
            }
        }
        return counts.map { hist in
            let total = Double(hist.reduce(0, +))
            guard total > 0 else { return (0..<bins).map { (Double($0) + 1) / Double(bins) } }
            let limit = max(1, clip * total / Double(bins))
            var excess = 0.0
            for h in hist { excess += max(Double(h) - limit, 0) }
            let add = excess / Double(bins)
            var cum = 0.0
            return hist.map { cum += min(Double($0), limit) + add; return cum / total }
        }
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, tiles: Int, clip: Double, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0 else { return rgb }
        let g = grid(tiles: tiles, width: width, height: height)
        let lut = luts(rgb, width: width, height: height, tiles: tiles, clip: clip)
        let tw = Double(width) / Double(g.x), th = Double(height) / Double(g.y)
        return rgb.indices.map { i in
            let x = Double(i % width), y = Double(i / width)
            let (lum, e) = encodedLuma(rgb[i])
            guard lum > 1e-6, lum <= 1 else { return rgb[i] }
            let bin = min(bins - 1, Int((e * Double(bins)).rounded(.down)))
            let fx = (x + 0.5) / tw - 0.5, fy = (y + 0.5) / th - 0.5
            let i0 = Int(fx.rounded(.down)), j0 = Int(fy.rounded(.down))
            let wx = fx - Double(i0), wy = fy - Double(j0)
            let a0 = min(max(i0, 0), g.x - 1), a1 = min(max(i0 + 1, 0), g.x - 1), b0 = min(max(j0, 0), g.y - 1), b1 = min(max(j0 + 1, 0), g.y - 1)
            let v = (lut[b0 * g.x + a0][bin] * (1 - wx) + lut[b0 * g.x + a1][bin] * wx) * (1 - wy) + (lut[b1 * g.x + a0][bin] * (1 - wx) + lut[b1 * g.x + a1][bin] * wx) * wy
            let gain = Transfer.srgbToLinear(v) / lum
            return rgb[i] * (1 + amount * (gain - 1))
        }
    }
}
