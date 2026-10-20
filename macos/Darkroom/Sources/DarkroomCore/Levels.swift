// Method: classic levels (black point, white point, gamma from a grey point), written from the rgblevels card's formula
import Foundation

/// Levels with black, grey and white points, the same on every channel, applied to the sRGB-encoded value.
/// Defaults (0, 0.5, 1) are the identity. Values above white keep rising, so HDR is kept.
public enum Levels {
    /// One linear channel through the steps above.
    public static func apply(_ v: Double, black: Double, grey: Double, white: Double) -> Double {
        let hi = max(white, black + 0.01)
        let mid = min(max(grey, 0.01), 0.99)
        let e = Transfer.linearToSRGB(v)
        let t = (e - black) / (hi - black)
        let gamma = log(0.5) / log(mid)
        let shaped = t <= 0 ? 0 : pow(t, gamma)
        return Transfer.srgbToLinear(shaped)
    }

    /// All three channels, each on its own.
    public static func apply(_ p: SIMD3<Double>, black: Double, grey: Double, white: Double) -> SIMD3<Double> {
        SIMD3(apply(p.x, black: black, grey: grey, white: white),
              apply(p.y, black: black, grey: grey, white: white),
              apply(p.z, black: black, grey: grey, white: white))
    }
}
