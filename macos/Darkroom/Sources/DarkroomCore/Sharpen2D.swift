// Method: unsharp mask on the square root of luminance, s = sqrt(Y) (Anscombe 1948, as DetailCommon), with the blur a
// cumulative à trous B3 spline chain (Starck and Murtagh, A&A 288, 1994), s' = s + amount (s - base), and the change
// given back to the pixel as a gain (DetailCommon.applying), so hue and chroma ratios stay put.
//
// The 2-D sharpen behind the catalogue's `sharpen` entry (Simple mode's Detail slider). The blur level grows with the
// radius: level 0 reaches 2 pixels, each level after doubles the reach. The GPU twin is DarkroomMetal's MetalSharpen2D.

import Foundation

public enum Sharpen2D {
    /// The blur the radius asks for, between two neighbouring cascades (cascade k is the à trous levels 0...k applied in turn, cascade -1 is no blur):
    /// radius 1, 2, 4, 8 are cascades 0, 1, 2, 3 as before, radii in between blend the two nearest by log2, and a radius under 1 blends from no blur to cascade 0.
    /// (A whole-level jump made every radius at preview scale, where the radius is under 1, the same picture.)
    public static func cascades(radius: Double) -> (lo: Int, hi: Int, weight: Double) {
        guard radius.isFinite, radius > 0 else { return (-1, -1, 0) }
        if radius < 1 { return (-1, 0, radius) }
        let t = min(log2(radius), 3)
        let l = Int(t.rounded(.down))
        return l >= 3 ? (3, 3, 0) : (l, l + 1, t - Double(l))
    }

    /// The unsharp mask of `rgb` (row-major, `width` by `height`). `amount` 0 or less returns the input untouched.
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, amount: Double, radius: Double) -> [SIMD3<Double>] {
        guard amount > 0 else { return rgb }
        let s = DetailCommon.sqrtLuminance(rgb, width: width, height: height)
        let c = cascades(radius: radius)
        var levels: [Plane] = [s]   // levels[k + 1] is cascade k
        if c.hi >= 0 { for j in 0...c.hi { levels.append(Filters.atrousSmooth(levels.last!, level: j)) } }
        let base = c.weight == 0 ? levels[c.lo + 1] : Plane.zip(levels[c.lo + 1], levels[c.hi + 1]) { $0 + c.weight * ($1 - $0) }
        let sharp = Plane.zip(s, base) { $0 + amount * ($0 - $1) }
        return DetailCommon.applying(sqrtLuminance: sharp, to: rgb)
    }
}
