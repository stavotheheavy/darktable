// Method: OkLab (Björn Ottosson, "A perceptual color space for image processing", 2020); the pixel's a and b are mixed toward a fixed
// chroma at the chosen hue by `strength`, lightness untouched. Strength 0 is the identity and strength 1 gives every pixel the tint's
// chroma, so the picture becomes a one-hue print with its own lightness.

import Foundation

public enum Colorize {
    /// OkLab chroma of the full tint.
    public static let chroma = 0.08

    /// The tint's OkLab (a, b) for a hue given as a fraction of the circle (0...1).
    public static func tint(hue: Double) -> SIMD2<Double> {
        SIMD2(chroma * cos(2 * .pi * hue), chroma * sin(2 * .pi * hue))
    }

    public static func apply(_ rgb: SIMD3<Double>, strength: Double, hue: Double) -> SIMD3<Double> {
        var lab = OkLab.fromWorking(rgb)
        let t = tint(hue: hue)
        lab.y += (t.x - lab.y) * strength
        lab.z += (t.y - lab.z) * strength
        return OkLab.toWorking(lab)
    }
}
