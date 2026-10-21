// Method: emboss (relief): the directional derivative of the display-encoded luminance (the sRGB transfer curve of IEC 61966-2-1) along the light direction, laid on mid-grey:
// relief = clamp(0.5 + strength (Ye(p + d) - Ye(p - d)), 0, 1) with d one pixel along the angle (0 degrees is to the right, 90 is up) and the two samples bilinear (`Remap.sample`).
// Flat areas become mid-grey, edges facing the light become light and edges away from it dark, as a stamped relief looks. The result is a grey picture mixed in by `amount`
// (0 is the identity).

import Foundation

public enum Emboss {
    static func encodedLuma(_ v: SIMD3<Double>) -> Double {
        let y = ColorCommon.luminance(v)
        return y.isNaN ? 0 : Transfer.linearToSRGB(min(max(y, 0), 1))
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, angleDegrees: Double, strength: Double, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0 else { return rgb }
        let t = angleDegrees * .pi / 180, dx = cos(t), dy = -sin(t)
        let y = rgb.map { v -> SIMD3<Double> in let l = ColorCommon.luminance(v); return SIMD3(l, l, l) }
        func ye(_ p: SIMD2<Double>) -> Double {
            let l = Remap.sample(y, width: width, height: height, at: p, channel: 0)
            return l.isNaN ? 0 : Transfer.linearToSRGB(min(max(l, 0), 1))
        }
        return rgb.indices.map { i in
            let x = Double(i % width), yy = Double(i / width)
            let relief = min(max(0.5 + strength * (ye(SIMD2(x + dx, yy + dy)) - ye(SIMD2(x - dx, yy - dy))), 0), 1)
            let g = Transfer.srgbToLinear(relief)
            return rgb[i] + amount * (SIMD3(repeating: g) - rgb[i])
        }
    }
}
