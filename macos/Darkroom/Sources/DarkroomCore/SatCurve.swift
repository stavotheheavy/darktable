// Method: OkLab (Björn Ottosson, "A perceptual color space for image processing", 2020); the chroma gain is a function of OkLab lightness, held flat outside the outer knots and a smoothstep between neighbouring knots.

import Foundation

/// Saturation by lightness: shadows, mids and highlights each get their own saturation change, blended smoothly over lightness.
/// OkLab a and b are scaled together, so hue and lightness never move. Zero sliders are the identity.
public enum SatCurve {
    /// OkLab lightness of the shadows, mids and highlights knots.
    public static let knots: [Double] = [0.15, 0.55, 0.9]

    /// The chroma gain at lightness `L` for sliders `u` (shadows, mids, highlights; each -1...1).
    public static func gain(L: Double, u: [Double]) -> Double {
        let s: Double
        if L <= knots[0] {
            s = u[0]
        } else if L >= knots[2] {
            s = u[2]
        } else {
            let lo = L < knots[1] ? 0 : 1
            let t = ColorCommon.smoothstep(knots[lo], knots[lo + 1], L)
            s = u[lo] * (1 - t) + u[lo + 1] * t
        }
        return max(1 + s, 0)
    }

    public static func apply(_ rgb: SIMD3<Double>, u: [Double]) -> SIMD3<Double> {
        var lab = OkLab.fromWorking(rgb)
        let k = gain(L: lab.x, u: u)
        lab.y *= k
        lab.z *= k
        return OkLab.toWorking(lab)
    }
}
