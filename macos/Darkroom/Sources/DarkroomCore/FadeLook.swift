// Method: the faded, matte print look: on the display-encoded value (the sRGB transfer curve of IEC 61966-2-1) the black is lifted to `black` and the white pulled
// down to 1 - `white`, with everything between scaled linearly: e' = black + (1 - black - white) e. Both at 0 is the identity. e is clamped to 0...1 first
// and a NaN is treated as black.

import Foundation

public enum FadeLook {
    public static func apply(_ rgb: SIMD3<Double>, black: Double, white: Double) -> SIMD3<Double> {
        func channel(_ v: Double) -> Double {
            let e = v.isNaN ? 0 : Transfer.linearToSRGB(min(max(v, 0), 1))
            return Transfer.srgbToLinear(black + (1 - black - white) * e)
        }
        return SIMD3(channel(rgb.x), channel(rgb.y), channel(rgb.z))
    }
}
