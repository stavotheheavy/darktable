// Colour maths for the clean engine.
//
// OkLab: Björn Ottosson, "A perceptual color space for image processing" (2020); the matrices are
// published there. sRGB, SMPTE ST 2084 (PQ) and ITU-R BT.2100 HLG are standards; BT.2020 primaries
// and D65 are standard values. The structure (a working space, OkLab/OkLCh built from it, matrices
// derived once) follows LightCraft's `lightcraft-color`
// (https://github.com/storytold/lightcraft, MIT OR Apache-2.0, Copyright (c) 2026 ArtCraft Team and
// the LightCraft contributors), re-written in Swift. See THIRD-PARTY.md.

import Foundation

/// Row-major 3x3 matrix in Double; converted to Float where pixels are processed.
public struct Mat3: Equatable, Sendable {
    public var m: [[Double]]
    public init(_ rows: [[Double]]) { m = rows }
    public static let identity = Mat3([[1, 0, 0], [0, 1, 0], [0, 0, 1]])

    public func mul(_ o: Mat3) -> Mat3 {
        var r = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { r[i][j] += m[i][k] * o.m[k][j] } } }
        return Mat3(r)
    }

    public func apply(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
              m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
              m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z)
    }

    /// nil when singular.
    public func inverse() -> Mat3? {
        let a = m
        let c00 = a[1][1] * a[2][2] - a[1][2] * a[2][1]
        let c01 = a[1][2] * a[2][0] - a[1][0] * a[2][2]
        let c02 = a[1][0] * a[2][1] - a[1][1] * a[2][0]
        let det = a[0][0] * c00 + a[0][1] * c01 + a[0][2] * c02
        guard abs(det) > 1e-14 else { return nil }
        let d = 1 / det
        return Mat3([
            [c00 * d, (a[0][2] * a[2][1] - a[0][1] * a[2][2]) * d, (a[0][1] * a[1][2] - a[0][2] * a[1][1]) * d],
            [c01 * d, (a[0][0] * a[2][2] - a[0][2] * a[2][0]) * d, (a[0][2] * a[1][0] - a[0][0] * a[1][2]) * d],
            [c02 * d, (a[0][1] * a[2][0] - a[0][0] * a[2][1]) * d, (a[0][0] * a[1][1] - a[0][1] * a[1][0]) * d],
        ])
    }
}

public enum ColorSpaces {
    /// CIE xy of the D65 white point.
    public static let d65 = SIMD2<Double>(0.3127, 0.3290)

    /// RGB to XYZ for a space given by its primaries and white point (xy). Derived, not typed in, so
    /// white maps to exactly the white point.
    public static func rgbToXYZ(r: SIMD2<Double>, g: SIMD2<Double>, b: SIMD2<Double>, white: SIMD2<Double>) -> Mat3 {
        func xyz(_ p: SIMD2<Double>) -> SIMD3<Double> { SIMD3(p.x / p.y, 1, (1 - p.x - p.y) / p.y) }
        let prim = Mat3([[xyz(r).x, xyz(g).x, xyz(b).x],
                         [xyz(r).y, xyz(g).y, xyz(b).y],
                         [xyz(r).z, xyz(g).z, xyz(b).z]])
        let s = prim.inverse()!.apply(xyz(white))
        return Mat3([[prim.m[0][0] * s.x, prim.m[0][1] * s.y, prim.m[0][2] * s.z],
                     [prim.m[1][0] * s.x, prim.m[1][1] * s.y, prim.m[1][2] * s.z],
                     [prim.m[2][0] * s.x, prim.m[2][1] * s.y, prim.m[2][2] * s.z]])
    }

    /// Linear BT.2020 (D65) to CIE XYZ.
    public static let rec2020ToXYZ = rgbToXYZ(r: SIMD2(0.708, 0.292), g: SIMD2(0.170, 0.797),
                                              b: SIMD2(0.131, 0.046), white: d65)
    /// Linear sRGB / Rec.709 (D65) to CIE XYZ.
    public static let srgbToXYZ = rgbToXYZ(r: SIMD2(0.640, 0.330), g: SIMD2(0.300, 0.600),
                                           b: SIMD2(0.150, 0.060), white: d65)
    /// Linear Display P3 (D65) to CIE XYZ.
    public static let p3ToXYZ = rgbToXYZ(r: SIMD2(0.680, 0.320), g: SIMD2(0.265, 0.690),
                                         b: SIMD2(0.150, 0.060), white: d65)

    /// The engine's WORKING space, the one every module's pixels are in: linear Rec.2020 primaries, Core Image's extended linear ITU-R
    /// 2020 (`CIEngine.makeContext` names it). It holds every colour a camera records and every colour a display can show, so no module
    /// works on negative components for ordinary colours, and the display transform maps into the OUTPUT gamut (sRGB, Display P3) only at
    /// the end. The luminance weights and the OkLab matrices are derived from it, here and in the Metal kernels.
    public static let workingToXYZ = rec2020ToXYZ
    public static var workingToSRGB: Mat3 { srgbToXYZ.inverse()!.mul(workingToXYZ) }
    public static var sRGBToWorking: Mat3 { workingToXYZ.inverse()!.mul(srgbToXYZ) }
    public static var workingToP3: Mat3 { p3ToXYZ.inverse()!.mul(workingToXYZ) }
    public static var p3ToWorking: Mat3 { workingToXYZ.inverse()!.mul(p3ToXYZ) }
    /// Linear Rec.2020 to linear sRGB (values outside 0...1 are out of gamut and left to the caller).
    public static var rec2020ToSRGB: Mat3 { srgbToXYZ.inverse()!.mul(rec2020ToXYZ) }
    public static var srgbToRec2020: Mat3 { rec2020ToXYZ.inverse()!.mul(srgbToXYZ) }
}

// MARK: - OkLab

public enum OkLab {
    private static let xyzToLMS = Mat3([
        [0.8189330101, 0.3618667424, -0.1288597137],
        [0.0329845436, 0.9293118715, 0.0361456387],
        [0.0482003018, 0.2643662691, 0.6338517070],
    ])
    /// Ottosson's published matrix, with each row closed exactly: L sums to 1 and a, b to 0, so equal LMS
    /// (any grey) is L = LMS, a = b = 0 to machine precision. The published values are rounded to 10 digits
    /// (the b row summed to 3.7e-8); closing them moves no coefficient by more than 4e-8.
    private static let lmsToLab: Mat3 = {
        let published = [
            [0.2104542553, 0.7936177850, -0.0040720468],
            [1.9779984951, -2.4285922050, 0.4505937099],
            [0.0259040371, 0.7827717662, -0.8086757660],
        ]
        let l = published[0].reduce(0, +)
        return Mat3([
            published[0].map { $0 / l },
            [published[1][0], published[1][1], -(published[1][0] + published[1][1])],
            [published[2][0], published[2][1], -(published[2][0] + published[2][1])],
        ])
    }()
    private static let toLMS = xyzToLMS.mul(ColorSpaces.rec2020ToXYZ)
    /// The engine's working space (linear Rec.2020 primaries) to LMS, and the matrices Metal kernels bake in
    /// (see DarkroomMetal's MetalColorCommon, generated from these so the two cannot disagree).
    /// Each row is scaled to sum to 1, so working white (and every grey) lands on equal LMS and so on
    /// a = b = 0 exactly: our primaries' white, built from the primaries, is a hair off the white OkLab's
    /// matrix assumes, which left greys with about 7e-5 of chroma and let colour filters tint them.
    public static let workingToLMS: Mat3 = {
        let m = xyzToLMS.mul(ColorSpaces.workingToXYZ).m
        return Mat3(m.map { row in let sum = row.reduce(0, +); return row.map { $0 / sum } })
    }()
    public static let workingFromLMS = workingToLMS.inverse()!
    public static let lmsToLabMatrix = lmsToLab
    public static let labToLMSMatrix = lmsToLab.inverse()!
    private static let fromLMS = toLMS.inverse()!
    private static let fromLab = lmsToLab.inverse()!

    /// Linear Rec.2020 to OkLab (L, a, b).
    public static func fromRec2020(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let lms = toLMS.apply(rgb)
        return lmsToLab.apply(SIMD3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z)))
    }

    public static func toRec2020(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let c = fromLab.apply(lab)
        return fromLMS.apply(SIMD3(c.x * c.x * c.x, c.y * c.y * c.y, c.z * c.z * c.z))
    }

    /// Linear working-space RGB (sRGB primaries, the engine's working space) to OkLab.
    public static func fromWorking(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let lms = workingToLMS.apply(rgb)
        return lmsToLab.apply(SIMD3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z)))
    }

    public static func toWorking(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let c = labToLMSMatrix.apply(lab)
        return workingFromLMS.apply(SIMD3(c.x * c.x * c.x, c.y * c.y * c.y, c.z * c.z * c.z))
    }

    /// (L, chroma, hue in radians -pi...pi)
    public static func lch(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(lab.x, hypot(lab.y, lab.z), atan2(lab.z, lab.y))
    }

    public static func lab(_ lch: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(lch.x, lch.y * cos(lch.z), lch.y * sin(lch.z))
    }
}

// MARK: - Transfer functions (standards)

public enum Transfer {
    public static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    public static func linearToSRGB(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static let m1 = 2610.0 / 16384.0
    private static let m2 = 2523.0 / 4096.0 * 128.0
    private static let c1 = 3424.0 / 4096.0
    private static let c2 = 2413.0 / 4096.0 * 32.0
    private static let c3 = 2392.0 / 4096.0 * 32.0

    /// ST 2084 inverse EOTF: absolute luminance / 10000 cd/m2 to code value 0...1.
    public static func pqEncode(_ y: Double) -> Double {
        let p = pow(min(max(y, 0), 1), m1)
        return pow((c1 + c2 * p) / (1 + c3 * p), m2)
    }

    public static func pqDecode(_ e: Double) -> Double {
        let p = pow(min(max(e, 0), 1), 1 / m2)
        return pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    private static let hlgA = 0.17883277
    private static let hlgB = 0.28466892
    private static let hlgC = 0.55991073

    public static func hlgEncode(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot() : hlgA * log(12 * e - hlgB) + hlgC
    }

    public static func hlgDecode(_ s: Double) -> Double {
        s <= 0.5 ? s * s / 3 : (exp((s - hlgC) / hlgA) + hlgB) / 12
    }
}

// MARK: - Shared per-pixel helpers (the Metal twins live in DarkroomMetal's MetalColorCommon)

public enum ColorCommon {
    /// The luminance weights of the working space: the Y row of its RGB-to-XYZ matrix (0.2627, 0.6780, 0.0593 for Rec.2020), normalised
    /// to sum to one. Every module that needs a luminance (detail, noise, zones, the tone stage) and every Metal twin takes them from here.
    public static let lumaWeights: SIMD3<Double> = {
        let y = ColorSpaces.workingToXYZ.m[1]
        let s = y[0] + y[1] + y[2]
        return SIMD3(y[0] / s, y[1] / s, y[2] / s)
    }()

    /// Luminance of linear working-space RGB.
    public static func luminance(_ rgb: SIMD3<Double>) -> Double { lumaWeights.x * rgb.x + lumaWeights.y * rgb.y + lumaWeights.z * rgb.z }

    /// Hermite smoothstep: 0 below `e0`, 1 above `e1`, 3t^2 - 2t^3 between.
    public static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The signed smallest difference between two hue angles in radians, in -pi...pi.
    public static func hueDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }
}
