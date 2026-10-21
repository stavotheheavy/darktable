// Method: a warm / cool and a magenta / green look slider in OkLab (Björn Ottosson, 2020): `warmth` moves (a, b) toward yellow-orange (+b, a little +a) or
// blue (-b), `tint` toward magenta (+a) or green (-a), by fixed amounts, weighted by smoothstep(0, 0.1, L) so black takes no cast. It is a look applied after
// the picture is white balanced, not a white balance (that is `temperature`): lightness is untouched. Zero settings are the identity.

import Foundation

public enum Warmth {
    public static let warmthB = 0.04, warmthA = 0.01, tintA = 0.03

    public static func apply(_ rgb: SIMD3<Double>, warmth: Double, tint: Double) -> SIMD3<Double> {
        var lab = OkLab.fromWorking(rgb)
        let w = ColorCommon.smoothstep(0, 0.1, lab.x)
        lab.y += w * (warmthA * warmth + tintA * tint)
        lab.z += w * warmthB * warmth
        return OkLab.toWorking(lab)
    }
}
