// Method: the bleach bypass (skip-bleach) look of film printing, where the silver is left in: the picture is partly desaturated toward its luminance
// and then given the contrast of a second, black-and-white layer on top, an overlay blend with that luminance (the overlay formula of the PDF / Photoshop
// blend modes). On the display-encoded value (sRGB transfer curve, IEC 61966-2-1), with Y the Rec.709 luminance of the encoded colour:
//   d = e + 0.6 s (Y - e)                           (desaturate)
//   o = 2 d Y if d < 0.5 else 1 - 2 (1 - d)(1 - Y)  (overlay of Y on d)
//   out = d + s (o - d).
// `strength` s in 0...1; 0 is the identity. e is clamped to 0...1 and a NaN is treated as black.

import Foundation

public enum BleachBypass {
    public static let desaturation = 0.6

    public static func apply(_ rgb: SIMD3<Double>, strength s: Double) -> SIMD3<Double> {
        func enc(_ v: Double) -> Double { v.isNaN ? 0 : Transfer.linearToSRGB(min(max(v, 0), 1)) }
        let e = SIMD3(enc(rgb.x), enc(rgb.y), enc(rgb.z))
        let y = 0.2126 * e.x + 0.7152 * e.y + 0.0722 * e.z
        func channel(_ v: Double) -> Double {
            let d = v + desaturation * s * (y - v)
            let o = d < 0.5 ? 2 * d * y : 1 - 2 * (1 - d) * (1 - y)
            return Transfer.srgbToLinear(min(max(d + s * (o - d), 0), 1))
        }
        return SIMD3(channel(e.x), channel(e.y), channel(e.z))
    }
}
