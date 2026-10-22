// Method: drawn selections as grey pictures of the upright photo (the same MaskRaster the brush makes, so no new GPU kernel).
// Lasso: even-odd scanline fill of the closed polygon sampled at pixel centres (Foley, van Dam, Feiner and Hughes, "Computer
// Graphics: Principles and Practice", polygon filling), edge spans weighted by their fractional pixel coverage, then feathered
// with three box passes (a close match to a Gaussian, Wells 1986). Linear: weight falls from 1 at the first point to 0 at the
// second along their axis with the Hermite smoothstep. Radial: an axis-aligned ellipse centred on the first point whose
// half-axes are the distances to the second point; weight 1 inside the inner fraction, smoothstep to 0 at the rim.
// Everything is in the UPRIGHT picture, normalised 0...1, y down.

import Foundation

public enum MaskShape: String, Sendable, Codable, CaseIterable {
    case lasso, linear, radial
}

public enum MaskShapes {
    /// A raster of `shape` drawn through `points` on a `width` by `height` picture. `feather` is 0...1: for a lasso the edge blur
    /// as a share of 5 percent of the diagonal, for a radial the width of the soft rim as a share of the radius; linear ignores it.
    public static func rasterize(_ shape: MaskShape, points: [SIMD2<Double>], feather: Double, width: Int, height: Int, id: String) -> MaskRaster {
        let clean = points.map { SIMD2($0.x.isFinite ? min(max($0.x, -0.5), 1.5) : 0, $0.y.isFinite ? min(max($0.y, -0.5), 1.5) : 0) }
        let f = min(max(feather.isFinite ? feather : 0, 0), 1)
        var w: [Double]
        switch shape {
        case .lasso: w = lasso(clean, feather: f, width: width, height: height)
        case .linear: w = linear(clean, width: width, height: height)
        case .radial: w = radial(clean, feather: f, width: width, height: height)
        }
        return MaskRaster(id: id, width: width, height: height, pixels: w.map { UInt8(min(max(($0 * 255).rounded(), 0), 255)) })
    }

    @inline(__always) static func smoothstep(_ t: Double) -> Double { let c = min(max(t, 0), 1); return c * c * (3 - 2 * c) }

    static func lasso(_ pts: [SIMD2<Double>], feather: Double, width: Int, height: Int) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        guard pts.count >= 3 else { return out }
        let p = pts.map { SIMD2($0.x * Double(width), $0.y * Double(height)) }
        let sub = 4   // sub-scanlines per pixel row, so a shallow edge gets fractional coverage
        for y in 0..<height {
            for s in 0..<sub {
                let sy = Double(y) + (Double(s) + 0.5) / Double(sub)
                var xs: [Double] = []
                for i in 0..<p.count {
                    let a = p[i], b = p[(i + 1) % p.count]
                    if (a.y <= sy && b.y > sy) || (b.y <= sy && a.y > sy) { xs.append(a.x + (sy - a.y) / (b.y - a.y) * (b.x - a.x)) }
                }
                xs.sort()
                var k = 0
                while k + 1 < xs.count {
                    let x0 = min(max(xs[k], 0), Double(width)), x1 = min(max(xs[k + 1], 0), Double(width))
                    k += 2
                    guard x1 > x0 else { continue }
                    let i0 = Int(x0), i1 = min(Int(x1), width - 1)
                    for x in i0...i1 {
                        let cover = min(x1, Double(x + 1)) - max(x0, Double(x))
                        if cover > 0 { out[y * width + x] += cover / Double(sub) }
                    }
                }
            }
        }
        let radius = feather * 0.05 * Double(width * width + height * height).squareRoot()
        return radius >= 0.5 ? blur(out, width: width, height: height, radius: radius) : out
    }

    static func linear(_ pts: [SIMD2<Double>], width: Int, height: Int) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        guard pts.count >= 2 else { return out }
        let a = SIMD2(pts[0].x * Double(width), pts[0].y * Double(height)), b = SIMD2(pts[1].x * Double(width), pts[1].y * Double(height))
        let d = b - a, len2 = d.x * d.x + d.y * d.y
        guard len2 > 1e-9 else { return out }
        for y in 0..<height { for x in 0..<width {
            let t = ((Double(x) + 0.5 - a.x) * d.x + (Double(y) + 0.5 - a.y) * d.y) / len2
            out[y * width + x] = 1 - smoothstep(t)
        } }
        return out
    }

    static func radial(_ pts: [SIMD2<Double>], feather: Double, width: Int, height: Int) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        guard pts.count >= 2 else { return out }
        let c = SIMD2(pts[0].x * Double(width), pts[0].y * Double(height))
        let rx = abs(pts[1].x - pts[0].x) * Double(width), ry = abs(pts[1].y - pts[0].y) * Double(height)
        guard rx >= 0.5, ry >= 0.5 else { return out }
        let inner = 1 - feather
        for y in 0..<height { for x in 0..<width {
            let dx = (Double(x) + 0.5 - c.x) / rx, dy = (Double(y) + 0.5 - c.y) / ry
            let d = (dx * dx + dy * dy).squareRoot()
            out[y * width + x] = d <= inner ? 1 : (d >= 1 ? 0 : 1 - smoothstep((d - inner) / max(1 - inner, 1e-6)))
        } }
        return out
    }

    /// Three box passes in each direction (edges clamped).
    static func blur(_ src: [Double], width: Int, height: Int, radius: Double) -> [Double] {
        let r = max(1, Int((radius / 1.7).rounded()))
        var a = src
        var tmp = [Double](repeating: 0, count: src.count)
        for _ in 0..<3 {
            for y in 0..<height {
                let row = y * width
                var sum = 0.0
                for k in -r...r { sum += a[row + min(max(k, 0), width - 1)] }
                for x in 0..<width {
                    tmp[row + x] = sum / Double(2 * r + 1)
                    sum += a[row + min(x + r + 1, width - 1)] - a[row + min(max(x - r, 0), width - 1)]
                }
            }
            for x in 0..<width {
                var sum = 0.0
                for k in -r...r { sum += tmp[min(max(k, 0), height - 1) * width + x] }
                for y in 0..<height {
                    a[y * width + x] = sum / Double(2 * r + 1)
                    sum += tmp[min(y + r + 1, height - 1) * width + x] - tmp[min(max(y - r, 0), height - 1) * width + x]
                }
            }
        }
        return a
    }
}
