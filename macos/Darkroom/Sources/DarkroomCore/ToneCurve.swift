// Method: Fritsch and Carlson, "Monotone Piecewise Cubic Interpolation", SIAM J. Numer. Anal. 17(2), 1980.
//
// A point curve: 2 to 8 points (x, y) with x strictly increasing, joined by a monotone cubic. The curve works on the
// sRGB-encoded value of each channel, so the points are placed where the eye sees them, and it is monotone, so it never
// reverses a tone. Outside the first and last point it extends linearly with that end's tangent, so HDR values keep
// rising and a first point right of 0 (or lower than 0.. a black point) pushes the shadows down.
//
// Interior tangents are the weighted mean of the two neighbouring slopes (the derivative of the parabola through three
// points); with evenly spaced points that is the plain mean the original five-node curve used, so a curve with the
// old five fixed positions evaluates as before. The CPU oracle here is checked by darkroom-core-check (TC1-TC6, TP1-TP7);
// the Metal kernel is checked against it by darkroom-metal-check.

import Foundation

public enum ToneCurve {
    /// The five fixed positions the first version of the curve had.
    public static let legacyXs = [0, 0.25, 0.5, 0.75, 1.0]
    public static let maxPoints = 8
    /// The least gap between two neighbouring points, so a curve cannot fold back on itself.
    public static let minGap = 0.02

    /// Points made safe to evaluate: 2...8 of them, x strictly increasing inside 0...1 with at least `minGap` between
    /// neighbours, y inside 0...1 and never decreasing (a tone is never reversed). Non-finite values become their
    /// neighbour's. A valid set comes back unchanged.
    public static func sanitized(xs: [Double], ys: [Double]) -> (xs: [Double], ys: [Double]) {
        let n = min(xs.count, ys.count, maxPoints)
        guard n >= 2 else { return ([0, 1], [0, 1]) }
        var px = [Double](repeating: 0, count: n), py = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let fallbackX = i == 0 ? 0 : px[i - 1] + minGap, fallbackY = i == 0 ? 0 : py[i - 1]
            px[i] = xs[i].isFinite ? min(max(xs[i], 0), 1) : fallbackX
            py[i] = ys[i].isFinite ? min(max(ys[i], 0), 1) : fallbackY
        }
        px[0] = min(px[0], 1 - minGap * Double(n - 1))
        for i in 1..<n { px[i] = max(px[i], px[i - 1] + minGap) }
        px[n - 1] = min(px[n - 1], 1)
        for i in stride(from: n - 2, through: 0, by: -1) { px[i] = min(px[i], px[i + 1] - minGap) }
        for i in 1..<n { py[i] = max(py[i], py[i - 1]) }
        return (px, py)
    }

    /// Fritsch-Carlson tangents for points (xs, ys), one per point.
    public static func tangents(xs: [Double], ys: [Double]) -> [Double] {
        let n = xs.count
        guard n >= 2, ys.count == n else { return [Double](repeating: 0, count: n) }
        var h = [Double](repeating: 0, count: n - 1), d = [Double](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) { h[k] = xs[k + 1] - xs[k]; d[k] = (ys[k + 1] - ys[k]) / h[k] }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if n > 2 {
            for k in 1..<(n - 1) {
                m[k] = d[k - 1] * d[k] > 0 ? (h[k] * d[k - 1] + h[k - 1] * d[k]) / (h[k - 1] + h[k]) : 0
            }
        }
        for k in 0..<(n - 1) {
            if d[k] == 0 {
                m[k] = 0
                m[k + 1] = 0
                continue
            }
            let a = m[k] / d[k], b = m[k + 1] / d[k]
            if a * a + b * b > 9 {
                let t = 3 / (a * a + b * b).squareRoot()
                m[k] = t * a * d[k]
                m[k + 1] = t * b * d[k]
            }
        }
        return m
    }

    /// The curve on an encoded value.
    public static func curve(_ e: Double, xs: [Double], ys: [Double], tangents m: [Double]) -> Double {
        let n = xs.count
        if e < xs[0] { return ys[0] + m[0] * (e - xs[0]) }
        if e > xs[n - 1] { return ys[n - 1] + m[n - 1] * (e - xs[n - 1]) }
        var k = 0
        while k < n - 2 && e >= xs[k + 1] { k += 1 }
        let h = xs[k + 1] - xs[k]
        let s = (e - xs[k]) / h
        let s2 = s * s, s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1, h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2, h11 = s3 - s2
        return h00 * ys[k] + h10 * h * m[k] + h01 * ys[k + 1] + h11 * h * m[k + 1]
    }

    /// One linear channel through encode, curve, decode. Both transfers are unclamped, so HDR passes through.
    public static func apply(_ v: Double, xs: [Double], ys: [Double]) -> Double {
        let m = tangents(xs: xs, ys: ys)
        return Transfer.srgbToLinear(curve(Transfer.linearToSRGB(v), xs: xs, ys: ys, tangents: m))
    }

    /// All three channels, each on its own.
    public static func apply(_ p: SIMD3<Double>, xs: [Double], ys: [Double]) -> SIMD3<Double> {
        let m = tangents(xs: xs, ys: ys)
        func one(_ v: Double) -> Double {
            Transfer.srgbToLinear(curve(Transfer.linearToSRGB(v), xs: xs, ys: ys, tangents: m))
        }
        return SIMD3(one(p.x), one(p.y), one(p.z))
    }

    /// What the Metal kernel reads: u[0] the point count, u[1...8] the x values, u[9...16] the y values, u[17...24] the tangents
    /// (unused slots 0). Give it points that came through `sanitized`.
    public static func uniforms(xs: [Double], ys: [Double]) -> [Float] {
        let m = tangents(xs: xs, ys: ys)
        func slots(_ v: [Double]) -> [Float] { (0..<maxPoints).map { $0 < v.count ? Float(v[$0]) : 0 } }
        return [Float(xs.count)] + slots(xs) + slots(ys) + slots(m)
    }

    // MARK: the first version's five fixed positions (the signatures the earlier checks and edits use)

    public static func tangents(_ ys: [Double]) -> [Double] { tangents(xs: legacyXs, ys: ys) }

    public static func curve(_ e: Double, ys: [Double], tangents m: [Double]) -> Double {
        curve(e, xs: legacyXs, ys: ys, tangents: m)
    }

    public static func apply(_ v: Double, ys: [Double]) -> Double { apply(v, xs: legacyXs, ys: ys) }

    public static func apply(_ p: SIMD3<Double>, ys: [Double]) -> SIMD3<Double> { apply(p, xs: legacyXs, ys: ys) }
}
