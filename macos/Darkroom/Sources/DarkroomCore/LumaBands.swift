// Method: an exposure change in stops by the pixel's own luminance, in five bands (blacks, shadows, midtones, highlights, whites) centred at -4, -2, 0, +1.5
// and +3 EV over middle grey (0.18). A pixel takes the raised-cosine blend of the two bands its log luminance falls between (the same blend as `ZoneExposure`),
// so the weights sum to one and the same change on every band is exactly a global exposure. Unlike `ZoneExposure` the lookup is the pixel's own luminance, not
// an edge-aware base, so it is the plain, cheap tone-range exposure (and it moves texture with the tone). The gain multiplies all three channels: colour
// ratios are kept. All zero is the identity.

import Foundation

public enum LumaBands {
    public static let centres: [Double] = [-4, -2, 0, 1.5, 3]
    public static let names = ["blacks", "shadows", "mids", "highlights", "whites"]

    /// The change in EV at base brightness `b` (EV over grey) for the five band changes.
    public static func gain(logLuminance b: Double, evs: [Double]) -> Double {
        let c = min(max(b.isFinite ? b : 0, centres[0]), centres[4])
        var k = 0
        while k < 3 && c >= centres[k + 1] { k += 1 }
        let f = (c - centres[k]) / (centres[k + 1] - centres[k])
        let upper = 0.5 * (1 - cos(Double.pi * f))
        return evs[k] * (1 - upper) + evs[k + 1] * upper
    }

    public static func apply(_ rgb: SIMD3<Double>, evs: [Double]) -> SIMD3<Double> {
        let y = max(ColorCommon.luminance(rgb), 1e-6)
        return rgb * pow(2, gain(logLuminance: log2(y / 0.18), evs: evs))
    }
}
