// Method: Richardson-Lucy deconvolution (W. H. Richardson, "Bayesian-Based Iterative Method of Image Restoration", JOSA 62, 1972; L. B. Lucy, "An iterative
// technique for the rectification of observed distributions", Astron. J. 79, 1974) with a symmetric blur as the point spread function (the three-box
// cascade of `Blur`): u(k+1) = u(k) * (P (*) (d / (P (*) u(k)))), started at the picture d. The correction factor is held to 0.25...4 and the divisor to 1e-4, which
// keeps the iteration from amplifying noise or dividing by black. The picture is mixed toward the result by `amount` (0 is the identity). A negative
// value counts as 0 in the ratio. Sharpens by undoing a blur of about `radius` pixels, as capture sharpening does, with less halo than an unsharp mask.

import Foundation

public enum Deconvolution {
    public static let floor = 1e-4, lowGain = 0.25, highGain = 4.0

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Double, iterations: Int, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0, radius > 0, iterations > 0 else { return rgb }
        var u = rgb
        for _ in 0..<iterations {
            let blurred = Blur.apply(u, width: width, height: height, radius: radius)
            let ratio = rgb.indices.map { i -> SIMD3<Double> in
                SIMD3(max(rgb[i].x, 0) / max(blurred[i].x, floor), max(rgb[i].y, 0) / max(blurred[i].y, floor), max(rgb[i].z, 0) / max(blurred[i].z, floor))
            }
            let corr = Blur.apply(ratio, width: width, height: height, radius: radius)
            u = u.indices.map { i in
                SIMD3(u[i].x * min(max(corr[i].x, lowGain), highGain), u[i].y * min(max(corr[i].y, lowGain), highGain), u[i].z * min(max(corr[i].z, lowGain), highGain))
            }
        }
        return rgb.indices.map { rgb[$0] + amount * (u[$0] - rgb[$0]) }
    }
}
