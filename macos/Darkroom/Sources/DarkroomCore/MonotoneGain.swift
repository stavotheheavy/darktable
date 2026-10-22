// Method: a gain in EV over a log-luminance axis, as the exposure change at ascending nodes joined by a monotone cubic Hermite curve
// (F. N. Fritsch and R. E. Carlson, "Monotone Piecewise Cubic Interpolation", SIAM J. Numer. Anal. 17, 1980), with the nodes of the output curve kept from falling.

import Foundation

/// The curve behind the luminosity bands and the zone exposure: input log luminance b (EV over grey) to output log luminance f(b) = b + gain(b). The raised-cosine blend of the node gains
/// that both modules used before could make f fall (a lift of one node over its neighbour by more than the distance between them), so a darker pixel came out brighter than a
/// lighter one and showed as contour lines and outlines. Here a node's output is lifted to the previous node's plus `minSlope` x the node distance when it would be lower, and the curve
/// through them is monotone. The same change on every node is exactly a global exposure (the data are on a line of slope 1) and all zero is the identity.
public enum MonotoneGain {
    /// The least slope (stops out per stop in) between two nodes.
    public static let minSlope = 0.2

    /// 2n values for n nodes: the node offsets in EV (output minus centre, after lifting the falling ones), then the Hermite slopes at the nodes.
    public static func prepared(centres c: [Double], evs: [Double]) -> [Double] {
        let n = c.count
        var t = (0..<n).map { c[$0] + (evs[$0].isFinite ? evs[$0] : 0) }
        for k in 1..<n { t[k] = max(t[k], t[k - 1] + minSlope * (c[k] - c[k - 1])) }
        let h = (0..<(n - 1)).map { c[$0 + 1] - c[$0] }
        let s = (0..<(n - 1)).map { (t[$0 + 1] - t[$0]) / h[$0] }
        var d = [Double](repeating: 1, count: n)
        d[0] = min(1, 2.9 * s[0]); d[n - 1] = min(1, 2.9 * s[n - 2])
        if n > 2 {
            for k in 1..<(n - 1) {
                let w1 = 2 * h[k] + h[k - 1], w2 = h[k] + 2 * h[k - 1]
                d[k] = (w1 + w2) / (w1 / s[k - 1] + w2 / s[k])
            }
        }
        return (0..<n).map { t[$0] - c[$0] } + d
    }

    /// The gain in EV at log luminance `b`, from `prepared`: the end nodes' offsets beyond them, the Hermite curve between.
    public static func gain(_ b: Double, centres c: [Double], prepared p: [Double]) -> Double {
        let n = c.count
        let b = b.isFinite ? b : 0
        if b <= c[0] { return p[0] }
        if b >= c[n - 1] { return p[n - 1] }
        var k = 0
        while k < n - 2 && b >= c[k + 1] { k += 1 }
        let h = c[k + 1] - c[k], t = (b - c[k]) / h, t2 = t * t, t3 = t2 * t
        let f0 = c[k] + p[k], f1 = c[k + 1] + p[k + 1]
        let f = (2 * t3 - 3 * t2 + 1) * f0 + (t3 - 2 * t2 + t) * h * p[n + k] + (-2 * t3 + 3 * t2) * f1 + (t3 - t2) * h * p[n + k + 1]
        return f - b
    }
}
