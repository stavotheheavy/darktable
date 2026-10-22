// Method: an exposure change in stops by the pixel's own luminance, in five bands (blacks, shadows, midtones, highlights, whites) centred at -4, -2, 0, +1.5
// and +3 EV over middle grey (0.18). A pixel takes the raised-cosine blend of the two bands its log luminance falls between (the same blend as `ZoneExposure`),
// so the weights sum to one and the same change on every band is exactly a global exposure. Unlike `ZoneExposure` the lookup is the pixel's own luminance, not
// an edge-aware base, so it is the plain, cheap tone-range exposure (and it moves texture with the tone). The gain multiplies all three channels: colour
// ratios are kept. All zero is the identity.
//
// The curve (log luminance in, log luminance out) is the band nodes joined by a monotone cubic (Fritsch and Carlson, SIAM J. Numer. Anal. 17, 1980), and the nodes are not
// allowed to fall: a node lower than the one before it plus `minSlope` stops per stop is lifted to it. With the raised-cosine blend of the gains, a strong lift in one band over a
// neighbour left (say shadows +3 with midtones 0) made the curve fall, so darker pixels came out brighter than lighter ones and showed as contour lines. Now a lift flattens the
// bands above it instead. The same change on every band is still exactly a global exposure, and all zero is still the identity.

import Foundation

public enum LumaBands {
    public static let centres: [Double] = [-4, -2, 0, 1.5, 3]
    public static let names = ["blacks", "shadows", "mids", "highlights", "whites"]

    /// The least slope (stops out per stop in) the curve may have between two bands.
    public static let minSlope = 0.2

    /// What the GPU reads: the five node offsets in EV (the node's output minus its centre, after lifting the falling ones) and the five Hermite slopes at the nodes. 10 values.
    public static func prepared(evs: [Double]) -> [Double] {
        var t = (0..<5).map { centres[$0] + (evs[$0].isFinite ? evs[$0] : 0) }
        for k in 1..<5 { t[k] = max(t[k], t[k - 1] + minSlope * (centres[k] - centres[k - 1])) }
        let h = (0..<4).map { centres[$0 + 1] - centres[$0] }
        let s = (0..<4).map { (t[$0 + 1] - t[$0]) / h[$0] }
        var d = [Double](repeating: 1, count: 5)
        d[0] = min(1, 2.9 * s[0]); d[4] = min(1, 2.9 * s[3])
        for k in 1..<4 {
            let w1 = 2 * h[k] + h[k - 1], w2 = h[k] + 2 * h[k - 1]
            d[k] = (w1 + w2) / (w1 / s[k - 1] + w2 / s[k])
        }
        return (0..<5).map { t[$0] - centres[$0] } + d
    }

    /// The change in EV at base brightness `b` (EV over grey), from `prepared`.
    public static func gain(logLuminance b: Double, prepared p: [Double]) -> Double {
        let b = b.isFinite ? b : 0
        if b <= centres[0] { return p[0] }
        if b >= centres[4] { return p[4] }
        var k = 0
        while k < 3 && b >= centres[k + 1] { k += 1 }
        let h = centres[k + 1] - centres[k], t = (b - centres[k]) / h, t2 = t * t, t3 = t2 * t
        let f0 = centres[k] + p[k], f1 = centres[k + 1] + p[k + 1]
        let f = (2 * t3 - 3 * t2 + 1) * f0 + (t3 - 2 * t2 + t) * h * p[5 + k] + (-2 * t3 + 3 * t2) * f1 + (t3 - t2) * h * p[5 + k + 1]
        return f - b
    }

    public static func gain(logLuminance b: Double, evs: [Double]) -> Double { gain(logLuminance: b, prepared: prepared(evs: evs)) }

    public static func apply(_ rgb: SIMD3<Double>, evs: [Double]) -> SIMD3<Double> {
        let y = max(ColorCommon.luminance(rgb), 1e-6)
        return rgb * pow(2, gain(logLuminance: log2(y / 0.18), evs: evs))
    }
}
