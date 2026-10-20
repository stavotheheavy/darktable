// Method: Fritsch and Carlson, "Monotone Piecewise Cubic Interpolation", SIAM J. Numer. Anal. 17(2), 1980.
//
// Five-node tone curve. Nodes sit at x = 0, 0.25, 0.5, 0.75, 1 with heights ys. The curve works on the
// sRGB-encoded value of each channel, so the nodes are placed where the eye sees them, and it is
// monotone, so it never reverses a tone. Outside 0...1 it extends linearly, so HDR values keep rising.
// The CPU oracle here is checked by darkroom-core-check (TC1-TC5); the Metal kernel is checked against it
// by darkroom-metal-check.

public enum ToneCurve {
    static let h = 0.25

    /// Fritsch-Carlson tangents for the five node heights (step 1 and 2). Returns 5 values.
    public static func tangents(_ ys: [Double]) -> [Double] {
        var d = [Double](repeating: 0, count: 4)
        for k in 0..<4 { d[k] = (ys[k + 1] - ys[k]) / h }
        var m = [Double](repeating: 0, count: 5)
        m[0] = d[0]
        m[4] = d[3]
        for k in 1...3 { m[k] = d[k - 1] * d[k] > 0 ? (d[k - 1] + d[k]) / 2 : 0 }
        for k in 0..<4 {
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

    /// The curve on an encoded value (steps 3 and 4).
    public static func curve(_ e: Double, ys: [Double], tangents m: [Double]) -> Double {
        if e < 0 { return ys[0] + m[0] * e }
        if e > 1 { return ys[4] + m[4] * (e - 1) }
        let k = min(Int(e / h), 3)
        let s = (e - h * Double(k)) / h
        let s2 = s * s, s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1, h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2, h11 = s3 - s2
        return h00 * ys[k] + h10 * h * m[k] + h01 * ys[k + 1] + h11 * h * m[k + 1]
    }

    /// One linear channel through encode, curve, decode. Both transfers are unclamped, so HDR passes through.
    public static func apply(_ v: Double, ys: [Double]) -> Double {
        let m = tangents(ys)
        return Transfer.srgbToLinear(curve(Transfer.linearToSRGB(v), ys: ys, tangents: m))
    }

    /// All three channels, each on its own.
    public static func apply(_ p: SIMD3<Double>, ys: [Double]) -> SIMD3<Double> {
        let m = tangents(ys)
        func one(_ v: Double) -> Double {
            Transfer.srgbToLinear(curve(Transfer.linearToSRGB(v), ys: ys, tangents: m))
        }
        return SIMD3(one(p.x), one(p.y), one(p.z))
    }
}
