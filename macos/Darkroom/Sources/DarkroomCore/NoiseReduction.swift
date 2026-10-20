// Method: soft-threshold wavelet shrinkage (Donoho, "De-noising by soft-thresholding", IEEE Trans. Inf. Theory 41, 1995)
// on the a trous bands (Starck and Murtagh, "Image restoration with noise suppression using the wavelet transform",
// A&A 288, 1994). Luminance is shrunk in s = sqrt(Y), where shot noise is about uniform (Anscombe, Biometrika 35, 1948),
// and given back as a gain. Colour is shrunk in the ratios rgb / Y and renormalised so the luminance does not move.
//
// The GPU twin is DarkroomMetal's MetalNoiseReduction; darkroom-engine-check E-NR proves they agree.

import Foundation

public enum NoiseReduction {
    /// Standard deviations of the five finest B3 a trous detail bands for unit white noise.
    public static let bandNoise: [Double] = [0.890, 0.201, 0.086, 0.041, 0.020]

    /// Soft threshold: shrinks `d` towards zero by `t`, and gives zero inside the band (-t, t).
    public static func soft(_ d: Double, _ t: Double) -> Double {
        let m = max(abs(d) - t, 0)
        return d < 0 ? -m : m
    }

    /// Luminance noise (`luma`, stage 1) then colour noise (`chroma`, stage 2), both 0...1. Both 0 returns the input.
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, luma: Double, chroma: Double) -> [SIMD3<Double>] {
        guard luma != 0 || chroma != 0 else { return rgb }
        var out = rgb
        if luma != 0 { out = shrinkLuma(out, width: width, height: height, luma: luma) }
        if chroma != 0 { out = shrinkChroma(out, width: width, height: height, chroma: chroma) }
        return out
    }

    /// Stage 1: soft-threshold the bands of s = sqrt(Y) at 3 sigma for noise of 0.1 * luma, then give it back as a gain.
    static func shrinkLuma(_ rgb: [SIMD3<Double>], width: Int, height: Int, luma: Double) -> [SIMD3<Double>] {
        let s = DetailCommon.sqrtLuminance(rgb, width: width, height: height)
        let (bands, residual) = Filters.atrous(s, levels: 4)
        var s2 = residual
        for j in 0..<4 {
            let t = 3 * 0.1 * luma * bandNoise[j]
            s2 = Plane.zip(s2, bands[j]) { $0 + soft($1, t) }
        }
        return DetailCommon.applying(sqrtLuminance: s2, to: rgb)
    }

    /// Stage 2: shrink the bands of each ratio q = rgb / Y at 3 sigma for noise of 0.15 * chroma, then rebuild each pixel
    /// with its own luminance. Pixels at or under the minimum luminance are left alone and count as q = (1, 1, 1).
    static func shrinkChroma(_ rgb: [SIMD3<Double>], width: Int, height: Int, chroma: Double) -> [SIMD3<Double>] {
        let ys = rgb.map { ColorCommon.luminance($0) }
        var shrunk: [Plane] = []
        for c in 0..<3 {
            let q = Plane(width: width, height: height, values: zip(rgb, ys).map { px, y in
                y > DetailCommon.minLuminance ? px[c] / y : 1
            })
            let (bands, residual) = Filters.atrous(q, levels: 5)
            var q2 = residual
            for j in 0..<5 {
                let t = 3 * 0.15 * chroma * bandNoise[j]
                q2 = Plane.zip(q2, bands[j]) { $0 + soft($1, t) }
            }
            shrunk.append(q2)
        }
        return rgb.indices.map { i in
            let y = ys[i]
            guard y > DetailCommon.minLuminance else { return rgb[i] }
            let q2 = SIMD3(shrunk[0].values[i], shrunk[1].values[i], shrunk[2].values[i])
            let k = 0.2126 * q2.x + 0.7152 * q2.y + 0.0722 * q2.z
            guard k > 1e-6 else { return rgb[i] }
            return q2 * (y / k)
        }
    }
}
