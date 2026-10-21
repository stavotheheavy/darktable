// Method: contrast, brightness and saturation as three scene-referred moves, two of them already checked in `ColorBalance`: contrast is a
// power about middle grey (0.18) on scene luminance, so hue is kept; saturation scales OkLab chroma (Björn Ottosson, 2020), so lightness is
// kept; brightness is an exposure gain of 2^(2 * brightness), so a slider at 1 is +2 EV and at -1 is -2 EV.
//
// Core Image's colour controls did the same three jobs with a pivot at 0.5 and an additive brightness. On scene-linear data that moves
// black (an offset lifts it) and puts the pivot far above middle grey, so contrast and brightness read wrongly on a photo.

import Foundation

public enum Colisa {
    /// The gain brightness stands for: 2^(2 * brightness).
    public static func gain(brightness: Double) -> Double { pow(2, 2 * brightness) }

    /// Linear working-space RGB in, the same kind out. All three at 0 is the identity.
    public static func apply(_ rgb: SIMD3<Double>, contrast: Double, brightness: Double, saturation: Double) -> SIMD3<Double> {
        ColorBalance.apply(rgb, contrast: contrast, saturation: saturation, vibrance: 0) * gain(brightness: brightness)
    }
}
