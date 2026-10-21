// Method: the saturation step of `ColorBalance` on its own: OkLab chroma (Björn Ottosson, 2020) is multiplied by 1 + saturation, so
// hue and lightness are kept, a grey stays grey, and -1 removes all colour.
//
// Core Image's colour controls weighed the channels on the encoded value; this runs on the colour balance kernel, so it has no kernel of its own.

import Foundation

public enum ColorContrast {
    /// Linear working-space RGB in, the same kind out. `saturation` 0 is the identity.
    public static func apply(_ rgb: SIMD3<Double>, saturation: Double) -> SIMD3<Double> {
        ColorBalance.apply(rgb, contrast: 0, saturation: saturation, vibrance: 0)
    }
}
