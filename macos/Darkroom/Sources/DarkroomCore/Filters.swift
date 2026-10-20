// Method: box mean by separable sums; guided filter after He, Sun and Tang, "Guided Image Filtering", ECCV 2010
// (Algorithm 1); à trous wavelet with the B3 spline kernel (1, 4, 6, 4, 1) / 16 after Starck and Murtagh,
// "Image restoration with noise suppression using the wavelet transform", A&A 288, 1994.
//
// The neighbourhood filters the detail modules (S5: clarity, texture, dehaze, local contrast, noise, sharpen) are
// built on. One plane of Doubles, row-major, top-left origin. Edges are clamped: a pixel outside the image reads
// its nearest edge pixel. The engine's Metal versions (DarkroomMetal, MetalFilters) must match these, including at
// tile seams (darkroom-engine-check F-series renders regions and compares them with the full frame).

import Foundation

public struct Plane: Sendable, Equatable {
    public let width: Int, height: Int
    public var values: [Double]

    public init(width: Int, height: Int, values: [Double]) {
        precondition(values.count == width * height, "plane size mismatch")
        self.width = width; self.height = height; self.values = values
    }

    public init(width: Int, height: Int, fill: Double) {
        self.init(width: width, height: height, values: [Double](repeating: fill, count: width * height))
    }

    /// The value at (x, y), with coordinates outside the plane clamped to its nearest edge.
    @inline(__always) public func at(_ x: Int, _ y: Int) -> Double {
        values[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }

    public static func zip(_ a: Plane, _ b: Plane, _ f: (Double, Double) -> Double) -> Plane {
        precondition(a.width == b.width && a.height == b.height)
        return Plane(width: a.width, height: a.height, values: Swift.zip(a.values, b.values).map(f))
    }

    public func map(_ f: (Double) -> Double) -> Plane { Plane(width: width, height: height, values: values.map(f)) }
}

public enum Filters {
    /// The mean over the (2r + 1) by (2r + 1) square around each pixel, edges clamped. r = 0 is the identity.
    public static func boxMean(_ p: Plane, radius r: Int) -> Plane {
        guard r > 0 else { return p }
        let n = Double(2 * r + 1)
        var rows = Plane(width: p.width, height: p.height, fill: 0)
        for y in 0..<p.height {
            for x in 0..<p.width {
                var s = 0.0
                for k in -r...r { s += p.at(x + k, y) }
                rows.values[y * p.width + x] = s / n
            }
        }
        var out = Plane(width: p.width, height: p.height, fill: 0)
        for y in 0..<p.height {
            for x in 0..<p.width {
                var s = 0.0
                for k in -r...r { s += rows.at(x, y + k) }
                out.values[y * p.width + x] = s / n
            }
        }
        return out
    }

    /// The guided filter: smooths `input` while keeping the edges of `guide`. `eps` is the variance an edge needs to be kept
    /// (larger eps smooths across more). Self-guided (guide == input) it is edge-preserving smoothing.
    public static func guided(guide i: Plane, input p: Plane, radius r: Int, eps: Double) -> Plane {
        let meanI = boxMean(i, radius: r), meanP = boxMean(p, radius: r)
        let corrI = boxMean(Plane.zip(i, i, *), radius: r), corrIP = boxMean(Plane.zip(i, p, *), radius: r)
        let varI = Plane.zip(corrI, meanI) { $0 - $1 * $1 }
        let covIP = Plane.zip(corrIP, Plane.zip(meanI, meanP, *), -)
        let a = Plane.zip(covIP, varI) { $0 / ($1 + eps) }
        let b = Plane.zip(meanP, Plane.zip(a, meanI, *), -)
        let meanA = boxMean(a, radius: r), meanB = boxMean(b, radius: r)
        return Plane.zip(Plane.zip(meanA, i, *), meanB, +)
    }

    /// The minimum over the (2r + 1) by (2r + 1) square around each pixel, edges clamped (so the window shrinks at the
    /// border). Separable. r = 0 is the identity. The dark channel's patch minimum (He, Sun and Tang, "Single Image Haze
    /// Removal Using Dark Channel Prior", CVPR 2009).
    public static func minFilter(_ p: Plane, radius r: Int) -> Plane {
        guard r > 0 else { return p }
        var rows = Plane(width: p.width, height: p.height, fill: 0)
        for y in 0..<p.height {
            for x in 0..<p.width {
                var m = Double.infinity
                for k in -r...r { m = Swift.min(m, p.at(x + k, y)) }
                rows.values[y * p.width + x] = m
            }
        }
        var out = Plane(width: p.width, height: p.height, fill: 0)
        for y in 0..<p.height {
            for x in 0..<p.width {
                var m = Double.infinity
                for k in -r...r { m = Swift.min(m, rows.at(x, y + k)) }
                out.values[y * p.width + x] = m
            }
        }
        return out
    }

    /// The B3 spline weights of the à trous transform.
    public static let b3: [Double] = [1, 4, 6, 4, 1].map { $0 / 16 }

    /// One à trous smoothing at `level` (holes of 2^level between the taps), separable, edges clamped.
    public static func atrousSmooth(_ p: Plane, level: Int) -> Plane {
        let step = 1 << level
        var rows = Plane(width: p.width, height: p.height, fill: 0)
        for y in 0..<p.height {
            for x in 0..<p.width {
                var s = 0.0
                for (k, w) in b3.enumerated() { s += w * p.at(x + (k - 2) * step, y) }
                rows.values[y * p.width + x] = s
            }
        }
        var out = Plane(width: p.width, height: p.height, fill: 0)
        for y in 0..<p.height {
            for x in 0..<p.width {
                var s = 0.0
                for (k, w) in b3.enumerated() { s += w * rows.at(x, y + (k - 2) * step) }
                out.values[y * p.width + x] = s
            }
        }
        return out
    }

    /// Splits `p` into `levels` detail bands (finest first) and a residual; they sum back to `p` exactly.
    public static func atrous(_ p: Plane, levels: Int) -> (details: [Plane], residual: Plane) {
        var current = p, details: [Plane] = []
        for j in 0..<levels {
            let smooth = atrousSmooth(current, level: j)
            details.append(Plane.zip(current, smooth, -))
            current = smooth
        }
        return (details, current)
    }
}
