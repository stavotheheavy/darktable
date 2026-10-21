// Method: a monotone cubic curve (Fritsch and Carlson, SIAM J. Numer. Anal. 17(2), 1980; `ToneCurve`) on the OkLab lightness (Björn Ottosson, 2020) alone:
// L' = curve(L) with the pixel's chroma vector (a, b) unchanged, so a contrast curve moves tone without the saturation shifts of a per-channel curve. The five
// nodes sit at x = 0, 0.25, 0.5, 0.75, 1 of lightness, as the RGB curve's do; the default heights are the identity. L is clamped to 0...1 before the curve.

import Foundation

public enum LumaCurve {
    public static func apply(_ rgb: SIMD3<Double>, ys: [Double]) -> SIMD3<Double> {
        let p = ToneCurve.sanitized(xs: ToneCurve.legacyXs, ys: ys)
        let m = ToneCurve.tangents(xs: p.xs, ys: p.ys)
        var lab = OkLab.fromWorking(rgb)
        let l = min(max(lab.x.isNaN ? 0 : lab.x, 0), 1)
        lab.x = ToneCurve.curve(l, xs: p.xs, ys: p.ys, tangents: m)
        return OkLab.toWorking(lab)
    }
}
