// Method: non-local means denoising (A. Buades, B. Coll and J.-M. Morel, "A non-local algorithm for image denoising", CVPR 2005): each pixel becomes the weighted mean of the
// pixels in a 7 x 7 search window around it, the weight of a candidate exp(-d^2 / h^2) with d^2 the mean squared difference between the 3 x 3 patch around the candidate and the 3 x 3
// patch around the pixel, over the three channels, taken on the square root of the scene value (the variance-stabilising domain of `DetailCommon`). Pixels in similar
// surroundings count, wherever they are, so noise averages away and structure (which only matches itself) stays. The averaged values are the linear ones. Reads are clamped at
// the frame edge. The result is mixed in by `amount` (0 is the identity).

import Foundation

public enum NonLocalMeans {
    public static let patchRadius = 1, searchRadius = 3

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, h: Double, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0 else { return rgb }
        let u = rgb.map { SIMD3(sqrt(max($0.x, 0)), sqrt(max($0.y, 0)), sqrt(max($0.z, 0))) }
        func at(_ x: Int, _ y: Int) -> Int { min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1) }
        var out = rgb
        let norm = Double((2 * patchRadius + 1) * (2 * patchRadius + 1) * 3)
        for y in 0..<height {
            for x in 0..<width {
                var sum = SIMD3<Double>(repeating: 0), wsum = 0.0
                for dy in -searchRadius...searchRadius {
                    for dx in -searchRadius...searchRadius {
                        var d2 = 0.0
                        for j in -patchRadius...patchRadius {
                            for i in -patchRadius...patchRadius {
                                let diff = u[at(x + dx + i, y + dy + j)] - u[at(x + i, y + j)]
                                d2 += diff.x * diff.x + diff.y * diff.y + diff.z * diff.z
                            }
                        }
                        let wt = exp(-(d2 / norm) / (h * h))
                        sum += rgb[at(x + dx, y + dy)] * wt; wsum += wt
                    }
                }
                out[y * width + x] = rgb[y * width + x] + amount * (sum / wsum - rgb[y * width + x])
            }
        }
        return out
    }
}
