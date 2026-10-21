// Method: shadows and highlights as two controls of the zone exposure (`ZoneExposure`): an exposure change by zone read from the
// picture's edge-aware smoothed brightness (guided filter, K. He, J. Sun, X. Tang, ECCV 2010), so the dark part of the picture lifts or the
// bright part holds by a smooth gain that follows regions, not texture, and colour ratios are kept.
//
// The sliders run -100...100 and stand for -2...+2 EV on the zones that make up the shadows (below middle grey) or the highlights (above
// it), spread by `ZoneExposure`'s own weights. Positive is lighter at both ends: shadows +100 lifts the dark part by up to 2 EV, highlights
// -100 pulls the bright part down by up to 2 EV. Both at 0 is the identity.

import Foundation

public enum Shadhi {
    /// The slider value that stands for one EV on the zone exposure.
    public static let sliderPerEV = 50.0

    /// The zone exposure settings for these two sliders.
    public static func settings(shadows: Double, highlights: Double) -> ZoneExposure.Settings {
        ZoneExposure.Settings(shadows: shadows / sliderPerEV, highlights: highlights / sliderPerEV)
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, shadows: Double, highlights: Double) -> [SIMD3<Double>] {
        ZoneExposure.apply(rgb, width: width, height: height, settings: settings(shadows: shadows, highlights: highlights))
    }
}
