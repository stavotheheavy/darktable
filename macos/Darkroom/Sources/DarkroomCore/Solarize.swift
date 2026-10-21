// Method: solarisation (the Sabattier effect of the darkroom): tones above a threshold are mirrored about it, so the light parts of the
// picture turn back toward dark while the shadows are kept. On the display-encoded value (the sRGB transfer curve of IEC 61966-2-1,
// `Transfer`), per channel: f(e) = e for e <= t and 2t - e above t (continuous at t); the result is e + strength * (f(e) - e), so strength 0 is
// the identity and strength 1 the full fold. e is clamped to 0...1 first and a NaN is treated as black.

import Foundation

public enum Solarize {
    public static func apply(_ rgb: SIMD3<Double>, threshold: Double, strength: Double) -> SIMD3<Double> {
        SIMD3(channel(rgb.x, threshold, strength), channel(rgb.y, threshold, strength), channel(rgb.z, threshold, strength))
    }

    static func channel(_ v: Double, _ t: Double, _ s: Double) -> Double {
        let e = v.isNaN ? 0 : Transfer.linearToSRGB(min(max(v, 0), 1))
        let folded = e > t ? 2 * t - e : e
        return Transfer.srgbToLinear(min(max(e + s * (folded - e), 0), 1))
    }
}
