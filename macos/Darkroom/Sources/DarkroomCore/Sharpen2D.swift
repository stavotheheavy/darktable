// Method: unsharp mask on the square root of luminance, s = sqrt(Y) (Anscombe 1948, as DetailCommon), with the blur a
// cumulative à trous B3 spline chain (Starck and Murtagh, A&A 288, 1994), s' = s + amount (s - base), and the change
// given back to the pixel as a gain (DetailCommon.applying), so hue and chroma ratios stay put.
//
// The 2-D sharpen behind the catalogue's `sharpen` entry (Simple mode's Detail slider). The blur level grows with the
// radius: level 0 reaches 2 pixels, each level after doubles the reach. The GPU twin is DarkroomMetal's MetalSharpen2D.

import Foundation

public enum Sharpen2D {
    /// The blur level for a radius: round(log2 radius), clamped to 0...3, so radius 1 blurs with level 0 and 8 with level 3.
    public static func level(radius: Double) -> Int {
        Int(min(max(log2(max(radius, 1)).rounded(), 0), 3))
    }

    /// The unsharp mask of `rgb` (row-major, `width` by `height`). `amount` 0 or less returns the input untouched.
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, amount: Double, radius: Double) -> [SIMD3<Double>] {
        guard amount > 0 else { return rgb }
        let s = DetailCommon.sqrtLuminance(rgb, width: width, height: height)
        var base = s
        for j in 0...level(radius: radius) { base = Filters.atrousSmooth(base, level: j) }
        let sharp = Plane.zip(s, base) { $0 + amount * ($0 - $1) }
        return DetailCommon.applying(sqrtLuminance: sharp, to: rgb)
    }
}
