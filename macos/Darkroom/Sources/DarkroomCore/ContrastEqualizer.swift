// Method: à trous wavelet equalizer after Starck and Murtagh, "Image restoration with noise suppression using the wavelet
// transform", A&A 288, 1994, on the square root of luminance (Anscombe, "The transformation of Poisson, binomial and
// negative-binomial data", Biometrika 35, 1948), the change given back to the pixel as a gain (DetailCommon).
//
// Five detail bands split the square root of luminance into scales: d0 and d1 are the finest, d4 the coarsest. Each
// slider is a gain 1 + value on a group of scales: fine (texture) on d0 and d1, medium on d2 and d3, coarse (clarity)
// on d4. -1 removes the group, 0 keeps it, +1 doubles it. The GPU twin is DarkroomMetal's MetalContrastEqualizer.

import Foundation

public enum ContrastEqualizer {
    /// The image with its detail scales re-weighted. All three sliders at 0 return the input untouched.
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, fine: Double, medium: Double, coarse: Double) -> [SIMD3<Double>] {
        guard fine != 0 || medium != 0 || coarse != 0 else { return rgb }
        let s = DetailCommon.sqrtLuminance(rgb, width: width, height: height)
        let (bands, residual) = Filters.atrous(s, levels: 5)
        let gains = [1 + fine, 1 + fine, 1 + medium, 1 + medium, 1 + coarse]
        let values = residual.values.indices.map { i in
            var out = residual.values[i]
            for j in 0..<5 { out += gains[j] * bands[j].values[i] }
            return out
        }
        return DetailCommon.applying(sqrtLuminance: Plane(width: width, height: height, values: values), to: rgb)
    }
}
