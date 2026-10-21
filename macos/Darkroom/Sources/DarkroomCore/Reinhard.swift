// Method: the extended Reinhard tone operator (E. Reinhard, M. Stark, P. Shirley and J. Ferwerda, "Photographic Tone Reproduction for Digital Images",
// SIGGRAPH 2002, equation 4): Ld = L (1 + L / W^2) / (1 + L), with W the smallest scene luminance that maps to white. Applied to the luminance and the colour
// scaled by Ld / L, so hue and ratios are kept, mixed in by `amount`: 0 is the identity. A luminance of 0 or less is left as it is.

import Foundation

public enum Reinhard {
    public static func apply(_ rgb: SIMD3<Double>, white w: Double, amount: Double) -> SIMD3<Double> {
        let y = ColorCommon.luminance(rgb)
        guard y > 0, y.isFinite else { return rgb }
        let ld = y * (1 + y / (w * w)) / (1 + y)
        return rgb * (1 + amount * (ld / y - 1))
    }
}
