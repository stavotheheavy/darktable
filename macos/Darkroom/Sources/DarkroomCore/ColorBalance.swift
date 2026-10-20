// Method: OkLab (Björn Ottosson, "A perceptual color space for image processing", 2020) for the chroma step; contrast is a power about middle grey on scene luminance; vibrance weights the chroma gain by how dull the colour is (this card's maths, see colorbalance.md).

import Foundation

/// Simple's Contrast and Color sliders in OkLab. Contrast scales every channel by the same factor, so hue is
/// kept; saturation and vibrance scale OkLab a and b and leave L alone.
public enum ColorBalance {
    public static func apply(_ rgb: SIMD3<Double>, contrast: Double, saturation: Double, vibrance: Double) -> SIMD3<Double> {
        var c = rgb
        let y = ColorCommon.luminance(c)
        // a black pixel has no luminance to scale: pow(0, negative) would be infinite
        if y > 0 { c *= pow(y / 0.18, contrast) }
        var lab = OkLab.fromWorking(c)
        let chroma = hypot(lab.y, lab.z)
        let f = 1 + saturation
        let w = 1 - ColorCommon.smoothstep(0, 0.2, chroma)
        let k = max(f * (1 + vibrance * w), 0)
        lab.y *= k
        lab.z *= k
        return OkLab.toWorking(lab)
    }
}
