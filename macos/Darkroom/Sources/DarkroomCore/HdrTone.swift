// Method: dynamic range compression by base and detail (F. Durand and J. Dorsey, "Fast Bilateral Filtering for the Display of High-Dynamic-Range Images",
// SIGGRAPH 2002, with the guided filter of K. He, J. Sun and X. Tang, ECCV 2010, as the smoother, exactly the base `ZoneExposure` uses). The log luminance is split
// into a smooth edge-aware base and the detail on top; the base is pulled toward middle grey by `amount` (base' = (1 - amount) base, in EV over grey) and
// the detail is kept, so large bright and dark regions move toward each other while texture keeps its contrast. The gain is a multiplication of all three
// channels, 2^(-amount * base), with the base held to -7...+3 EV. Amount 0 is the identity.

import Foundation

public enum HdrTone {
    public static let low = -7.0, high = 3.0

    public static func gainEV(base b: Double, amount: Double) -> Double {
        -amount * min(max(b.isFinite ? b : 0, low), high)
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, amount: Double, scale: Double) -> [SIMD3<Double>] {
        guard amount != 0 else { return rgb }
        let z = Plane(width: width, height: height, values: rgb.map { ZoneExposure.logLuminance($0) })
        let r = ZoneExposure.radius(scale: scale, longSide: max(width, height))
        let base = Filters.guided(guide: z, input: z, radius: r, eps: ZoneExposure.eps)
        return rgb.enumerated().map { i, p in p * pow(2, gainEV(base: base.values[i], amount: amount)) }
    }
}
