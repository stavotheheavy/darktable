// Method: the median filter (J. W. Tukey, Exploratory Data Analysis, 1977): each channel of each pixel becomes the median of the (2r + 1) by (2r + 1) square around
// it, edges clamped. It removes isolated hot, dead and noisy pixels while keeping edges, which a blur does not. The result is mixed in by `amount` (0 is the identity).
// `radius` is 1 (3 x 3) or 2 (5 x 5).

import Foundation

public enum MedianDenoise {
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Int, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0, radius > 0 else { return rgb }
        var out = rgb
        var window = [Double](repeating: 0, count: (2 * radius + 1) * (2 * radius + 1))
        for y in 0..<height {
            for x in 0..<width {
                var med = SIMD3<Double>(repeating: 0)
                for c in 0..<3 {
                    var n = 0
                    for dy in -radius...radius {
                        for dx in -radius...radius {
                            let px = min(max(x + dx, 0), width - 1), py = min(max(y + dy, 0), height - 1)
                            window[n] = rgb[py * width + px][c]; n += 1
                        }
                    }
                    window.sort()
                    med[c] = window[n / 2]
                }
                out[y * width + x] = rgb[y * width + x] + amount * (med - rgb[y * width + x])
            }
        }
        return out
    }
}
