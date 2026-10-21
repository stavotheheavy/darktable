// Method: a power curve on the display-encoded value (the sRGB transfer curve of IEC 61966-2-1, `Transfer`): out = e^gamma, per channel,
// with e clamped to 0...1. 0 and 1 stay put, a gamma above 1 darkens the tones between them and a gamma below 1 lightens them.
// A NaN is treated as black, so a bad pixel never spreads.

import Foundation

public enum BaseCurve {
    /// Linear working-space RGB in, the same kind out. A gamma of 1 is the identity on 0...1.
    public static func apply(_ rgb: SIMD3<Double>, gamma: Double) -> SIMD3<Double> {
        SIMD3(channel(rgb.x, gamma), channel(rgb.y, gamma), channel(rgb.z, gamma))
    }

    static func channel(_ v: Double, _ gamma: Double) -> Double {
        let e = v.isNaN ? 0 : Transfer.linearToSRGB(min(max(v, 0), 1))
        return Transfer.srgbToLinear(pow(e, gamma))
    }
}
