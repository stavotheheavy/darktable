// Method: the cross-processing look (developing slide film in negative chemistry), as three channel curves on the display-encoded value (the sRGB
// transfer curve of IEC 61966-2-1): with s(e) = smoothstep(0, 1, e), red is steepened (e + k_r a (s - e)), green a little (k_g), and blue is flattened and
// lifted in the shadows (e - k_b a (s - e) + 0.05 a (1 - e)): contrasty cyan-green shadows turning yellow-red in the highlights. `amount` a in 0...1;
// 0 is the identity. e is clamped to 0...1 and a NaN is treated as black.

import Foundation

public enum CrossProcess {
    public static let kRed = 1.0, kGreen = 0.5, kBlue = 0.6, blueLift = 0.05

    public static func apply(_ rgb: SIMD3<Double>, amount a: Double) -> SIMD3<Double> {
        func enc(_ v: Double) -> Double { v.isNaN ? 0 : Transfer.linearToSRGB(min(max(v, 0), 1)) }
        let e = SIMD3(enc(rgb.x), enc(rgb.y), enc(rgb.z))
        func s(_ x: Double) -> Double { ColorCommon.smoothstep(0, 1, x) }
        let r = e.x + kRed * a * (s(e.x) - e.x)
        let g = e.y + kGreen * a * (s(e.y) - e.y)
        let b = e.z - kBlue * a * (s(e.z) - e.z) + blueLift * a * (1 - e.z)
        func dec(_ x: Double) -> Double { Transfer.srgbToLinear(min(max(x, 0), 1)) }
        return SIMD3(dec(r), dec(g), dec(b))
    }
}
