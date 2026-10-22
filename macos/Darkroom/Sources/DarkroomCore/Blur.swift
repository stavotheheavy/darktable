// Method: a Gaussian-like blur from three box means in a row (the central limit theorem; W. M. Wells, "Efficient Synthesis of Gaussian
// Filters by Cascaded Uniform Filters", IEEE PAMI 1986), the same blur Bloom uses. It costs the same at any radius, keeps the light it
// was given away from the border, and clamps at the border like `Filters.boxMean`.
//
// A slider radius of r pixels becomes a box radius of round(r / 3) per pass (at least 1), so the blur reaches about r pixels. Radius 0
// (or a NaN) is the identity. `blurs` and `lowpass` are this blur; `soften` mixes it back over the picture.

import Foundation

public enum Blur {
    /// The box means in the blur.
    public static let passes = 3

    /// The box radius of each pass for a blur that reaches `px` pixels: 0 (no blur) for 0 or less. Fractional, so every slider position changes the picture:
    /// the old whole-pixel rounding sent every radius under 4.5 px to 1, and at preview scale that was most of the slider.
    public static func radius(px: Double) -> Double {
        guard px.isFinite, px > 0 else { return 0 }
        return min(px, 400) / Double(passes)
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Double) -> [SIMD3<Double>] {
        guard radius > 0 else { return rgb }
        var planes = (0..<3).map { c in Plane(width: width, height: height, values: rgb.map { $0[c] }) }
        for _ in 0..<passes { planes = planes.map { Filters.boxMean($0, radius: radius) } }
        return rgb.indices.map { i in SIMD3(planes[0].values[i], planes[1].values[i], planes[2].values[i]) }
    }
}
