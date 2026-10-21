// Method: the bilateral filter (C. Tomasi and R. Manduchi, "Bilateral filtering for gray and color images", ICCV 1998): each pixel becomes the mean of the (2R + 1) by (2R + 1)
// square around it weighted by a Gaussian of the spatial distance (sigma_s = max(R / 2, 0.5)) times a Gaussian of the colour difference (sigma_r) taken on the square root of the
// scene value over the three channels, so only pixels that are near and alike contribute and edges stay sharp. Reads are clamped at the frame edge. The result is mixed in by
// `amount` (0 is the identity). Radius 0 is the identity.

import Foundation

public enum BilateralFilter {
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius r: Int, range sigmaR: Double, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0, r > 0 else { return rgb }
        let u = rgb.map { SIMD3(sqrt(max($0.x, 0)), sqrt(max($0.y, 0)), sqrt(max($0.z, 0))) }
        let sigmaS = max(Double(r) / 2, 0.5)
        var out = rgb
        for y in 0..<height {
            for x in 0..<width {
                var sum = SIMD3<Double>(repeating: 0), wsum = 0.0
                let c = u[y * width + x]
                for dy in -r...r {
                    for dx in -r...r {
                        let q = min(max(y + dy, 0), height - 1) * width + min(max(x + dx, 0), width - 1)
                        let d = u[q] - c
                        let wt = exp(-Double(dx * dx + dy * dy) / (2 * sigmaS * sigmaS)) * exp(-(d.x * d.x + d.y * d.y + d.z * d.z) / (2 * sigmaR * sigmaR))
                        sum += rgb[q] * wt; wsum += wt
                    }
                }
                out[y * width + x] = rgb[y * width + x] + amount * (sum / wsum - rgb[y * width + x])
            }
        }
        return out
    }
}
