// Method: the high-pass layer of retouching: the detail of the picture, the display-encoded value minus its own blur (`Blur`, three box means), laid
// on mid-grey: out_e = 0.5 + strength * (e - blur(e)). Flat areas become mid-grey and edges and texture stand out as light and dark lines, which is
// the base of a high-pass sharpen or a frequency separation. e is the sRGB-encoded value (IEC 61966-2-1) clamped to 0...1; the result is clamped
// to 0...1. A radius of 0 gives a blur of nothing, so the result is the picture's own value minus itself: flat mid-grey.

import Foundation

public enum Highpass {
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, strength: Double, radius: Int) -> [SIMD3<Double>] {
        let encoded = rgb.map { v in SIMD3(enc(v.x), enc(v.y), enc(v.z)) }
        let blurred = Blur.apply(encoded, width: width, height: height, radius: radius)
        return rgb.indices.map { i in
            let e = encoded[i], b = blurred[i]
            func channel(_ k: Int) -> Double { Transfer.srgbToLinear(min(max(0.5 + strength * (e[k] - b[k]), 0), 1)) }
            return SIMD3(channel(0), channel(1), channel(2))
        }
    }

    static func enc(_ v: Double) -> Double { v.isNaN ? 0 : Transfer.linearToSRGB(min(max(v, 0), 1)) }
}
