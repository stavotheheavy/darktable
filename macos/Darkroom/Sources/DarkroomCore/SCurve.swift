// Method: a bias-and-gain contrast curve on the display-encoded value (the sRGB transfer curve of IEC 61966-2-1) about a pivot p, the gain form of C. Schlick,
// "Fast Alternatives to Perlin's Bias and Gain Functions", Graphics Gems IV, 1994, with the exponent k = 2^(1.5 contrast):
//   e' = p (e / p)^k                         for e <= p
//   e' = 1 - (1 - p) ((1 - e) / (1 - p))^k   for e > p.
// 0 and 1 and the pivot stay put; k above 1 is an S-curve (contrast up), below 1 flattens it. Contrast 0 is the identity. e is clamped to 0...1 and a NaN is
// treated as black.

import Foundation

public enum SCurve {
    public static func exponent(contrast: Double) -> Double { pow(2, 1.5 * contrast) }

    public static func apply(_ rgb: SIMD3<Double>, contrast: Double, pivot p: Double) -> SIMD3<Double> {
        let k = exponent(contrast: contrast)
        func channel(_ v: Double) -> Double {
            let e = v.isNaN ? 0 : Transfer.linearToSRGB(min(max(v, 0), 1))
            let o = e <= p ? p * pow(e / p, k) : 1 - (1 - p) * pow((1 - e) / (1 - p), k)
            return Transfer.srgbToLinear(min(max(o, 0), 1))
        }
        return SIMD3(channel(rgb.x), channel(rgb.y), channel(rgb.z))
    }
}
