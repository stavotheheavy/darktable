// Method: the monochrome card's filter formula, on OkLab (Björn Ottosson, "A perceptual color space for image processing", 2020) chroma and hue.
//
// Black and white with a coloured filter, as on film: colours near the filter's hue come out lighter, the
// opposite hue darker. Greys have no chroma, so the filter never changes them.

import Foundation

public enum Monochrome {
    /// Linear working-space RGB in, the same kind out. `intensity` 0 is the identity, 1 is full black and white.
    public static func apply(_ rgb: SIMD3<Double>, intensity: Double, filterHueDegrees: Double, filterStrength: Double) -> SIMD3<Double> {
        let y = ColorCommon.luminance(rgb)
        let lab = OkLab.fromWorking(rgb)
        let c = hypot(lab.y, lab.z)
        let hue = filterHueDegrees * .pi / 180
        // cos(hue - filter) times a chroma fade; the fade keeps near-greys from flipping on rounding noise
        let m = c < 1e-9 ? 0 : (lab.y * cos(hue) + lab.z * sin(hue)) / c * min(c / 0.15, 1)
        let yb = y * max(1 + filterStrength * m, 0)
        return rgb + intensity * (SIMD3(repeating: yb) - rgb)
    }
}
