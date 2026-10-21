// Method: a lens (bokeh) blur: every pixel becomes the weighted mean of the pixels inside a disc of `radius` pixels around it (edges clamped), the weight 1 + boost *
// smoothstep(0.6, 1.2, Y) of each source pixel, so bright highlights spread into the bright discs a real out-of-focus lens makes, where a Gaussian blur would only grey them.
// With boost 0 it is the plain disc mean. The result is mixed in by `amount` (0 is the identity). Radius 0 is the identity.

import Foundation

public enum LensBlur {
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Int, boost: Double, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0, radius > 0 else { return rgb }
        let weight = rgb.map { 1 + boost * ColorCommon.smoothstep(Bloom.kneeLow, Bloom.kneeHigh, ColorCommon.luminance($0)) }
        var out = rgb
        let r2 = radius * radius
        for y in 0..<height {
            for x in 0..<width {
                var sum = SIMD3<Double>(repeating: 0), wsum = 0.0
                for dy in -radius...radius {
                    for dx in -radius...radius where dx * dx + dy * dy <= r2 {
                        let px = min(max(x + dx, 0), width - 1), py = min(max(y + dy, 0), height - 1)
                        let wt = weight[py * width + px]
                        sum += rgb[py * width + px] * wt; wsum += wt
                    }
                }
                out[y * width + x] = rgb[y * width + x] + amount * (sum / wsum - rgb[y * width + x])
            }
        }
        return out
    }
}
