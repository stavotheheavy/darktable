// Method: uniform quantisation of the display-encoded value (the sRGB transfer curve of IEC 61966-2-1, `Transfer`) to `levels` steps per
// channel: e' = round(e * (levels - 1)) / (levels - 1), with e clamped to 0...1 (halves round away from zero). No noise is added.
// A NaN is treated as black.

import Foundation

public enum Posterize {
    public static func apply(_ rgb: SIMD3<Double>, levels: Double) -> SIMD3<Double> {
        let n = max(levels.rounded(), 2) - 1
        func channel(_ v: Double) -> Double {
            let e = v.isNaN ? 0 : Transfer.linearToSRGB(min(max(v, 0), 1))
            return Transfer.srgbToLinear((e * n).rounded() / n)
        }
        return SIMD3(channel(rgb.x), channel(rgb.y), channel(rgb.z))
    }
}
