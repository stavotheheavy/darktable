// Method: hue harmonisation in OkLab LCh (Björn Ottosson, 2020). A harmony scheme is a set of hues spaced evenly round the wheel from a base hue: complementary (2, 180
// degrees apart), triad (3), tetrad (4), or analogous (3 hues 30 degrees apart centred on the base). Each pixel's hue is pulled toward the nearest scheme hue by
// `amount`, strongly when it is already close and not at all half way to the next one (the pull is d (1 - smoothstep(0, g, |d|)) with d the signed distance to the nearest
// scheme hue and g the half gap), so the result is continuous round the wheel. Chroma and lightness are kept and greys are untouched (the pull is weighted by
// smoothstep(0, 0.04, chroma)). Amount 0 is the identity.

import Foundation

public enum ColorHarmony {
    public static let schemeNames = ["complementary", "triad", "tetrad", "analogous"]

    /// The scheme hues in radians and the half gap to the next (also radians) for scheme 0...3 at a base hue in degrees.
    public static func scheme(_ index: Int, baseDegrees: Double) -> (hues: [Double], halfGap: Double) {
        let base = baseDegrees * .pi / 180
        switch index {
        case 0: return ([base, base + .pi], .pi / 2)
        case 1: return ((0..<3).map { base + Double($0) * 2 * .pi / 3 }, .pi / 3)
        case 2: return ((0..<4).map { base + Double($0) * .pi / 2 }, .pi / 4)
        default: return ([base - .pi / 6, base, base + .pi / 6], .pi / 12)
        }
    }

    public static func apply(_ rgb: SIMD3<Double>, hues: [Double], halfGap g: Double, amount: Double) -> SIMD3<Double> {
        var lab = OkLab.fromWorking(rgb)
        let c = hypot(lab.y, lab.z)
        guard c > 0, c.isFinite else { return rgb }
        let h = atan2(lab.z, lab.y)
        var best: Double?
        for t in hues {
            let d = ColorCommon.hueDifference(t, h)
            if best == nil || abs(d) < abs(best!) { best = d }
        }
        let nearest = best ?? 0
        let pull = amount * ColorCommon.smoothstep(0, 0.04, c) * (1 - ColorCommon.smoothstep(0, g, abs(nearest)))
        let h2 = h + nearest * pull
        lab.y = c * cos(h2)
        lab.z = c * sin(h2)
        return OkLab.toWorking(lab)
    }
}
