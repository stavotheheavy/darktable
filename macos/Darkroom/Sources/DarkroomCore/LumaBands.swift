// Method: an exposure change in stops by the pixel's own luminance, in five bands (blacks, shadows, midtones, highlights, whites) centred at -4, -2, 0, +1.5
// and +3 EV over middle grey (0.18). A pixel takes the raised-cosine blend of the two bands its log luminance falls between (the same blend as `ZoneExposure`),
// so the weights sum to one and the same change on every band is exactly a global exposure. Unlike `ZoneExposure` the lookup is the pixel's own luminance, not
// an edge-aware base, so it is the plain, cheap tone-range exposure (and it moves texture with the tone). The gain multiplies all three channels: colour
// ratios are kept. All zero is the identity.
//
// The curve is `MonotoneGain`: the band nodes joined by a monotone cubic, the nodes kept from falling (a strong lift in one band over its neighbour used to invert tones and draw
// contour lines; now it flattens the bands above it). The same change on every band is still exactly a global exposure, and all zero is still the identity.

import Foundation

public enum LumaBands {
    public static let centres: [Double] = [-4, -2, 0, 1.5, 3]
    public static let names = ["blacks", "shadows", "mids", "highlights", "whites"]

    /// What the GPU reads: 10 values from `MonotoneGain.prepared` (five node offsets, five Hermite slopes).
    public static func prepared(evs: [Double]) -> [Double] { MonotoneGain.prepared(centres: centres, evs: evs) }

    /// The change in EV at base brightness `b` (EV over grey), from `prepared`.
    public static func gain(logLuminance b: Double, prepared p: [Double]) -> Double { MonotoneGain.gain(b, centres: centres, prepared: p) }

    public static func gain(logLuminance b: Double, evs: [Double]) -> Double { gain(logLuminance: b, prepared: prepared(evs: evs)) }

    public static func apply(_ rgb: SIMD3<Double>, evs: [Double]) -> SIMD3<Double> {
        let y = max(ColorCommon.luminance(rgb), 1e-6)
        return rgb * pow(2, gain(logLuminance: log2(y / 0.18), evs: evs))
    }
}
