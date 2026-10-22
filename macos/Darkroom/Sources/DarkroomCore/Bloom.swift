// Method: a glow around the bright parts, as a camera's soft-focus bloom: the picture's highlights (a soft threshold on scene luminance)
// are blurred and added back to the picture. The blur is three box means in a row, which approach a Gaussian (the central limit theorem;
// W. M. Wells, "Efficient Synthesis of Gaussian Filters by Cascaded Uniform Filters", IEEE PAMI 1986) and cost the same at any radius.
//
// Light only goes up: the glow is added, never subtracted, and a picture with nothing above the threshold comes back untouched. Away from
// the border the blur keeps the light it was given, so the added light is `strength` times the light of the highlights.
//
// Settings: strength 0...1 (0 is the identity); size, how far the glow reaches in pixels (three passes of size / 3 each).

import Foundation

public enum Bloom {
    /// Scene luminance below which a pixel gives no glow, and above which it gives all of its light.
    public static let kneeLow = 0.6, kneeHigh = 1.2
    /// The box means in the blur.
    public static let passes = 3

    /// The box radius of each pass for a glow that reaches `size` pixels, fractional so every size changes the glow (0 for a size of 0 or less).
    public static func radius(size: Double) -> Double {
        let s = size.isFinite ? min(max(size, 0), 400) : 0
        return s / Double(passes)
    }

    /// The light a pixel gives to the glow: itself, weighted by how far its luminance is over the knee.
    public static func bright(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        rgb * ColorCommon.smoothstep(kneeLow, kneeHigh, ColorCommon.luminance(rgb))
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, strength: Double, radius: Double) -> [SIMD3<Double>] {
        guard strength != 0 else { return rgb }
        let lit = rgb.map { bright($0) }
        var planes = (0..<3).map { c in Plane(width: width, height: height, values: lit.map { $0[c] }) }
        for _ in 0..<passes { planes = planes.map { Filters.boxMean($0, radius: radius) } }
        return rgb.indices.map { i in rgb[i] + strength * SIMD3(planes[0].values[i], planes[1].values[i], planes[2].values[i]) }
    }
}
