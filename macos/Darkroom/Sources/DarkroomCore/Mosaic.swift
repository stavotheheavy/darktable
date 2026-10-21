// Method: a mosaic: the frame is cut into square blocks from its top-left corner and every pixel shows the pixel at the centre of its
// block (floor-aligned, so a block of size s covers x in [k*s, k*s + s) and shows x = k*s + s/2; the last, partial block shows its
// centre clamped to the frame). A block of 1 is the identity.

import Foundation

public enum Mosaic {
    /// The block size in pixels for a pixelation setting at a render scale: at least 1, 400 at most.
    public static func block(pixelation: Double, scale: Double) -> Int {
        let b = pixelation * scale
        guard b.isFinite else { return 1 }
        return max(1, min(Int(b.rounded()), 400))
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, block s: Int) -> [SIMD3<Double>] {
        guard s > 1 else { return rgb }
        var out = rgb
        for y in 0..<height {
            let cy = min((y / s) * s + s / 2, height - 1)
            for x in 0..<width {
                let cx = min((x / s) * s + s / 2, width - 1)
                out[y * width + x] = rgb[cy * width + cx]
            }
        }
        return out
    }
}
