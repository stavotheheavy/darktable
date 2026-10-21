// Method: brightness and contrast as two scene-referred moves of `Colisa`: contrast is a power about middle grey (0.18) on scene luminance,
// so hue is kept; brightness is an exposure gain of 2^(2 * brightness), so a slider at 1 is +2 EV and at -1 is -2 EV.
//
// Core Image's colour controls added the brightness (lifting black) and pivoted the contrast at 0.5; on scene-linear data that reads wrongly.
// It runs on the colisa kernel with the saturation at 0, so it has no kernel of its own.

import Foundation

public enum ColorCorrection {
    /// Linear working-space RGB in, the same kind out. Both at 0 is the identity.
    public static func apply(_ rgb: SIMD3<Double>, brightness: Double, contrast: Double) -> SIMD3<Double> {
        Colisa.apply(rgb, contrast: contrast, brightness: brightness, saturation: 0)
    }
}
