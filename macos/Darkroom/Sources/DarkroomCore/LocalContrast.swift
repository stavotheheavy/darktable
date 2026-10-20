// Method: guided filter local contrast after He, Sun and Tang, "Guided Image Filtering", ECCV 2010: a self-guided guided
// filter is an edge-preserving smoother, so the boost s + detail (s - base) does not spill across strong edges. Works on
// the square root of luminance (DetailCommon, Anscombe 1948).
//
// Detail 0 is the identity. Positive detail raises local contrast, negative detail flattens it (-1 removes all detail
// finer than the radius). The GPU twin is DarkroomMetal's CIBridge.localContrast; darkroom-engine-check E-LC proves they agree.

import Foundation

public enum LocalContrast {
    /// The guided filter's eps on s: an edge in s needs a local standard deviation above 0.1 to be kept.
    public static let eps = 0.01

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, detail: Double, radius: Double) -> [SIMD3<Double>] {
        guard detail != 0 else { return rgb }
        let s = DetailCommon.sqrtLuminance(rgb, width: width, height: height)
        let base = Filters.guided(guide: s, input: s, radius: max(1, Int(radius.rounded())), eps: eps)
        let boosted = Plane.zip(s, base) { sv, bv in sv + detail * (sv - bv) }
        return DetailCommon.applying(sqrtLuminance: boosted, to: rgb)
    }
}
