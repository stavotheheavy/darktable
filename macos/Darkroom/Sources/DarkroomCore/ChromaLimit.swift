// Method: a soft limit on OkLab chroma (Björn Ottosson, 2020): below a knee at 0.8 of the limit chroma is untouched; above it the excess is compressed with
// tanh toward the limit, C' = k + (m - k) tanh((C - k) / (m - k)), so very saturated colours stop short of clipping and the curve is continuous with
// slope 1 at the knee. Hue and lightness are kept. A limit of 0.4 or more is no limit.

import Foundation

public enum ChromaLimit {
    public static let kneeFraction = 0.8
    public static let off = 0.4

    public static func compress(_ c: Double, limit m: Double) -> Double {
        let k = kneeFraction * m
        guard c > k else { return c }
        // tanh is 1 to machine precision from 20 on; the cap keeps a GPU float from overflowing inside it
        return k + (m - k) * tanh(min((c - k) / (m - k), 20))
    }

    public static func apply(_ rgb: SIMD3<Double>, limit m: Double) -> SIMD3<Double> {
        guard m < off else { return rgb }
        var lab = OkLab.fromWorking(rgb)
        let c = hypot(lab.y, lab.z)
        guard c > 0, c.isFinite else { return rgb }
        let k = compress(c, limit: m) / c
        lab.y *= k
        lab.z *= k
        return OkLab.toWorking(lab)
    }
}
