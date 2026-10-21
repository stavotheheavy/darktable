// Method: fill light as an exposure change through a window of tone: with b the pixel's log luminance in EV over middle grey (0.18), the change is `ev` stops weighted by a Gaussian of
// b about `center` (EV) whose full width at half maximum is `width` EV, w = exp(-(b - center)^2 / (2 sigma^2)) with sigma = width / (2 sqrt(2 ln 2)), so the tones near the centre are lifted
// (or pulled down) most and the rest fade out smoothly: gain = 2^(ev w), on all three channels, colour ratios kept. Ev 0 is the identity. The lookup is the pixel's own luminance, so
// unlike `shadhi` and `zones` it is not edge-aware; it is the quick, per-pixel fill.

import Foundation

public enum Relight {
    public static func gain(logLuminance b: Double, ev: Double, center: Double, width: Double) -> Double {
        let sigma = max(width, 1e-6) / 2.3548200450309493
        let d = (b.isFinite ? b : center) - center
        return pow(2, ev * exp(-d * d / (2 * sigma * sigma)))
    }

    public static func apply(_ rgb: SIMD3<Double>, ev: Double, center: Double, width: Double) -> SIMD3<Double> {
        let y = max(ColorCommon.luminance(rgb), 1e-6)
        return rgb * gain(logLuminance: log2(y / 0.18), ev: ev, center: center, width: width)
    }
}
