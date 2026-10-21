// Method: chromatic adaptation. The illuminant of the scene is a black body of a given colour temperature (its chromaticity from the cubic-spline
// fit of the Planckian locus of Kim, Kim and Choi, "Design of Advanced Color Temperature Control System for HDTV Applications", J. Korean Phys.
// Soc. 41, 2002, valid 1667 K to 25000 K); the Bradford cone-response transform (Lam, 1985) moves it to the D65 white of the working space; the
// result is a 3x3 matrix in the working space, optionally followed by a channel mixer's own 3x3. `strength` blends the adaptation with the identity.

import Foundation

public enum ChannelMixerRGB {
    /// CIE xy of a black body at `kelvin` (1667...25000, held to it).
    public static func illuminantXY(kelvin: Double) -> SIMD2<Double> {
        let t = min(max(kelvin.isFinite ? kelvin : 6500, 1667), 25000)
        let x: Double
        if t <= 4000 {
            x = -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        }
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        return SIMD2(x, y)
    }

    public static let bradford = Mat3([[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]])
    public static let d65 = SIMD2(0.3127, 0.3290)

    public static func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> { SIMD3(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y) }

    /// The adaptation matrix in working RGB that makes a surface lit by the `kelvin` illuminant read as under D65.
    public static func adaptation(kelvin: Double) -> Mat3 {
        let src = bradford.apply(xyz(illuminantXY(kelvin: kelvin))), dst = bradford.apply(xyz(d65))
        let scale = Mat3([[dst.x / src.x, 0, 0], [0, dst.y / src.y, 0], [0, 0, dst.z / src.z]])
        let cat = bradford.inverse()!.mul(scale).mul(bradford)
        return ColorSpaces.workingToXYZ.inverse()!.mul(cat).mul(ColorSpaces.workingToXYZ)
    }

    /// The module's matrix: the mixer rows after an adaptation of `strength` toward the `kelvin` illuminant.
    public static func matrix(kelvin: Double, strength: Double, rows: [[Double]]) -> [[Double]] {
        let a = adaptation(kelvin: kelvin).m
        let s = strength.isFinite ? min(max(strength, 0), 1) : 0
        var blended = [[Double]](repeating: [0, 0, 0], count: 3)
        for r in 0..<3 { for c in 0..<3 { blended[r][c] = (1 - s) * (r == c ? 1 : 0) + s * a[r][c] } }
        var out = [[Double]](repeating: [0, 0, 0], count: 3)
        for r in 0..<3 { for c in 0..<3 { out[r][c] = (0..<3).reduce(0) { $0 + rows[r][$1] * blended[$1][c] } } }
        return out
    }
}
