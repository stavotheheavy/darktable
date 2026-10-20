// Method: dark channel prior haze removal, He, Sun and Tang, "Single Image Haze Removal Using Dark Channel Prior",
// CVPR 2009: a hazy image is I = J t + A (1 - t); in a haze-free patch some channel is near 0, so the dark channel of
// I / A estimates 1 - t; the transmission is refined with the guided filter (He, Sun and Tang, ECCV 2010) and the
// scene is recovered as J = (I - A) / max(t, t0) + A. The airlight A is a module parameter (grey), not estimated from
// the image: a global estimate would make a tile or a region render differently from the whole frame.
//
// Fields: strength 0...1 (the "omega" of the paper; 0 is the identity), radius (dark channel patch half-width in
// pixels), airlight (brightness of the haze, scene-linear). The GPU twin is MetalDehaze.

import Foundation

public enum Dehaze {
    /// The paper's lower bound on the transmission: it keeps the recovery from amplifying noise without limit.
    public static let minTransmission = 0.1
    public static let refineEps = 1e-3

    /// The guided-filter radius for a dark channel patch radius.
    public static func refineRadius(patch r: Int) -> Int { 3 * r }

    /// The transmission map for `rgb`: 1 - strength * dark channel of (rgb / airlight), refined against the photo.
    public static func transmission(_ rgb: [SIMD3<Double>], width: Int, height: Int,
                                    strength: Double, radius: Int, airlight: Double) -> Plane {
        let a = max(airlight, 1e-6)
        let minRGB = Plane(width: width, height: height, values: rgb.map { max(min($0.x, $0.y, $0.z), 0) / a })
        let dark = Filters.minFilter(minRGB, radius: radius)
        let raw = dark.map { 1 - strength * $0 }
        let guide = DetailCommon.sqrtLuminance(rgb, width: width, height: height)
        return Filters.guided(guide: guide, input: raw, radius: refineRadius(patch: radius), eps: refineEps)
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int,
                             strength: Double, radius: Double, airlight: Double) -> [SIMD3<Double>] {
        guard strength > 0 else { return rgb }
        let r = max(1, Int(min(max(radius.rounded(), 1), 100)))
        let a = max(airlight, 1e-6)
        let t = transmission(rgb, width: width, height: height, strength: min(strength, 1), radius: r, airlight: a)
        return zip(rgb, t.values).map { c, tv in
            let tt = max(tv, minTransmission)
            return (c - SIMD3(repeating: a)) / tt + SIMD3(repeating: a)
        }
    }
}
