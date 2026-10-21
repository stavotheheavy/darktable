// Method: selective colour as the printing and prepress tradition does it (Photoshop's Selective Color, relative method): the picture is thought of as inks on the
// display-encoded value (the sRGB transfer curve of IEC 61966-2-1), c = 1 - R, m = 1 - G, y = 1 - B, k = min(c, m, y). Six colour families (reds, yellows, greens, cyans, blues,
// magentas, centred at the HSV hues 0, 60, ..., 300 degrees) each carry four sliders, cyan, magenta, yellow and black, -1...1. A pixel takes the blend of the families by the weights
// w_i = 1 - smoothstep(0, 60, hue distance) (which sum to 1), scaled by its colourfulness smoothstep(0, 0.1, max - min) so neutrals are untouched:
//   (dc, dm, dy, dk) = t sum w_i adjust_i;  k' = clamp(k (1 + dk));  c' = clamp(c (1 + dc) + k' - k), the same for m and y;  R' = 1 - c', ...
// Relative means the sliders scale the ink that is there. All zero is the identity.

import Foundation

public enum SelectiveColor {
    public static let families = ["reds", "yellows", "greens", "cyans", "blues", "magentas"]
    public static let inks = ["c", "m", "y", "k"]

    /// HSV hue in degrees of an encoded colour, and its colourfulness max - min.
    static func hueAndSpread(_ e: SIMD3<Double>) -> (hue: Double, spread: Double) {
        let mx = max(e.x, e.y, e.z), mn = min(e.x, e.y, e.z), d = mx - mn
        guard d > 0 else { return (0, 0) }
        var h: Double
        if mx == e.x { h = (e.y - e.z) / d } else if mx == e.y { h = (e.z - e.x) / d + 2 } else { h = (e.x - e.y) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, d)
    }

    /// `adjust` = reds c, m, y, k; yellows c, m, y, k; ... (24 values).
    public static func apply(_ rgb: SIMD3<Double>, adjust a: [Double]) -> SIMD3<Double> {
        func enc(_ v: Double) -> Double { v.isNaN ? 0 : Transfer.linearToSRGB(min(max(v, 0), 1)) }
        let e = SIMD3(enc(rgb.x), enc(rgb.y), enc(rgb.z))
        let (hue, spread) = hueAndSpread(e)
        let t = ColorCommon.smoothstep(0, 0.1, spread)
        guard t > 0 else { return rgb }
        var d = SIMD4<Double>(repeating: 0)
        for f in 0..<6 {
            var dist = abs(hue - Double(f) * 60)
            if dist > 180 { dist = 360 - dist }
            let wgt = 1 - ColorCommon.smoothstep(0, 60, dist)
            for k in 0..<4 { d[k] += wgt * a[f * 4 + k] }
        }
        d *= t
        let c = 1 - e.x, m = 1 - e.y, y = 1 - e.z
        let k = min(c, m, y)
        let k2 = min(max(k * (1 + d.w), 0), 1)
        func ink(_ v: Double, _ dv: Double) -> Double { Transfer.srgbToLinear(1 - min(max(v * (1 + dv) + k2 - k, 0), 1)) }
        return SIMD3(ink(c, d.x), ink(m, d.y), ink(y, d.z))
    }
}
