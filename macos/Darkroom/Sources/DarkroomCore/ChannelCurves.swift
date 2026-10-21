// Method: a monotone cubic curve (Fritsch and Carlson, SIAM J. Numer. Anal. 17(2), 1980; `ToneCurve`) of its own on each of the red, green and blue channels,
// on the display-encoded value. Each channel has the end points (0, 0) and (1, 1) and three movable nodes at x = 0.25, 0.5 and 0.75, so a channel at its
// defaults (y = 0.25, 0.5, 0.75) is the identity.

import Foundation

public enum ChannelCurves {
    public static let xs = [0.0, 0.25, 0.5, 0.75, 1.0]
    public static let channels = ["red", "green", "blue"]

    /// The sanitised point set of one channel from its three node heights.
    public static func points(_ y1: Double, _ y2: Double, _ y3: Double) -> (xs: [Double], ys: [Double]) {
        ToneCurve.sanitized(xs: xs, ys: [0, y1, y2, y3, 1])
    }

    /// `heights` = red (y1, y2, y3), green, blue: nine values.
    public static func apply(_ rgb: SIMD3<Double>, heights h: [Double]) -> SIMD3<Double> {
        func one(_ v: Double, _ c: Int) -> Double {
            let p = points(h[3 * c], h[3 * c + 1], h[3 * c + 2])
            return ToneCurve.apply(v, xs: p.xs, ys: p.ys)
        }
        return SIMD3(one(rgb.x, 0), one(rgb.y, 1), one(rgb.z, 2))
    }

    /// The kernel's uniforms: three `ToneCurve.uniforms` blocks of 25, red then green then blue.
    public static func uniforms(heights h: [Double]) -> [Float] {
        (0..<3).flatMap { c -> [Float] in
            let p = points(h[3 * c], h[3 * c + 1], h[3 * c + 2])
            return ToneCurve.uniforms(xs: p.xs, ys: p.ys)
        }
    }
}
