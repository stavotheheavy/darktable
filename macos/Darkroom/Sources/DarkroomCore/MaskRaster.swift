// Method: a painted or detected mask is a small grey picture of the upright photo; a pixel's weight is the picture sampled at its
// place (bilinear, edges clamped; Foley, van Dam, Feiner and Hughes, "Computer Graphics: Principles and Practice", on
// resampling). Brush strokes are rasterised by stamping soft round dabs along the path (a dab's weight falls from 1 at the inner
// radius to 0 at the outer one with the Hermite smoothstep), the stroke is the MAX of its dabs scaled by its flow so flow is a
// cap that does not depend on how finely the path is sampled, and strokes combine with the "over" rule (an eraser multiplies
// by the complement). Everything is in the UPRIGHT picture, normalised 0...1, y down.

import Foundation

public struct MaskRaster: Sendable, Equatable {
    /// Names these pixels (a layer id and the number of strokes in it): the key the engine caches its resampled copies by.
    public let id: String
    public let width: Int
    public let height: Int
    /// Row-major, row 0 on top, 0...255.
    public let pixels: [UInt8]

    public init(id: String, width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height, "raster size mismatch")
        self.id = id; self.width = width; self.height = height; self.pixels = pixels
    }

    /// The weight 0...1 at normalised upright coordinates (u, v), bilinear between pixel centres, clamped at the edges.
    public func sample(u: Double, v: Double) -> Double {
        guard u.isFinite, v.isFinite else { return 0 }
        let x = u * Double(width) - 0.5, y = v * Double(height) - 0.5
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = x - Double(x0), fy = y - Double(y0)
        func px(_ ix: Int, _ iy: Int) -> Double { Double(pixels[min(max(iy, 0), height - 1) * width + min(max(ix, 0), width - 1)]) / 255 }
        let top = px(x0, y0) * (1 - fx) + px(x0 + 1, y0) * fx
        let bottom = px(x0, y0 + 1) * (1 - fx) + px(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }
}

/// One brush stroke on the upright picture.
public struct BrushStroke: Sendable, Equatable, Codable {
    /// The path, normalised 0...1 (x right, y down).
    public var points: [SIMD2<Double>]
    /// Outer radius as a fraction of the picture's diagonal.
    public var radius: Double
    /// 0 a hard edge ... 1 soft all the way to the centre.
    public var softness: Double
    /// The most weight a stroke can lay down, 0...1.
    public var flow: Double
    public var erase: Bool
    /// How hard the pen pressed at each point, 0...1, one per point; nil for a stroke drawn with a mouse or a finger, which
    /// has the full radius all along. The radius at a point is `radius` scaled from 20% (no pressure) to 100% (full pressure).
    public var pressures: [Double]?

    public init(points: [SIMD2<Double>], radius: Double, softness: Double, flow: Double, erase: Bool, pressures: [Double]? = nil) {
        self.points = points; self.radius = radius; self.softness = softness; self.flow = flow; self.erase = erase
        self.pressures = pressures?.count == points.count ? pressures : nil
    }

    enum CodingKeys: String, CodingKey { case points, radius, softness, flow, erase, pressure }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let flat = try c.decode([Double].self, forKey: .points)
        points = stride(from: 0, to: flat.count - 1, by: 2).map { SIMD2(flat[$0], flat[$0 + 1]) }
        radius = try c.decode(Double.self, forKey: .radius)
        softness = try c.decode(Double.self, forKey: .softness)
        flow = try c.decode(Double.self, forKey: .flow)
        erase = try c.decode(Bool.self, forKey: .erase)
        // strokes saved before pen pressure existed have no such key
        let p = try c.decodeIfPresent([Double].self, forKey: .pressure)
        pressures = p?.count == points.count ? p : nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points.flatMap { [($0.x * 10000).rounded() / 10000, ($0.y * 10000).rounded() / 10000] }, forKey: .points)
        try c.encode(radius, forKey: .radius); try c.encode(softness, forKey: .softness)
        try c.encode(flow, forKey: .flow); try c.encode(erase, forKey: .erase)
        if let pressures { try c.encode(pressures.map { ($0 * 1000).rounded() / 1000 }, forKey: .pressure) }
    }
}

public enum Brush {
    /// The longest side of a painted raster, in pixels.
    public static let rasterSide = 1024
    /// Raster size for a picture of `aspect` (width over height).
    public static func rasterSize(aspect: Double) -> (width: Int, height: Int) {
        let a = aspect.isFinite && aspect > 0 ? aspect : 1
        return a >= 1 ? (rasterSide, max(8, Int((Double(rasterSide) / a).rounded()))) : (max(8, Int((Double(rasterSide) * a).rounded())), rasterSide)
    }

    /// A dab's weight at `distance` pixels from its centre: 1 inside the inner radius, 0 at the outer, smoothstep between.
    @inline(__always) static func dab(_ distance: Double, radius: Double, softness: Double) -> Double {
        let inner = radius * (1 - min(max(softness, 0), 1))
        if distance <= inner { return 1 }
        if distance >= radius { return 0 }
        let t = (distance - inner) / (radius - inner)
        return 1 - t * t * (3 - 2 * t)
    }

    /// The first `count` strokes laid down on a `width` by `height` raster of the upright picture.
    public static func rasterize(_ strokes: ArraySlice<BrushStroke>, width: Int, height: Int, id: String) -> MaskRaster {
        var layer = [Double](repeating: 0, count: width * height)
        let diagonal = (Double(width * width + height * height)).squareRoot()
        for stroke in strokes where !stroke.points.isEmpty {
            let radius = max(0.5, min(max(stroke.radius, 0), 1) * diagonal), flow = min(max(stroke.flow, 0), 1)
            // the stroke's own weights (max over its dabs), inside the path's bounding box grown by the radius
            let pts = stroke.points.map { SIMD2($0.x.isFinite ? min(max($0.x, -0.5), 1.5) : 0, $0.y.isFinite ? min(max($0.y, -0.5), 1.5) : 0) * SIMD2(Double(width), Double(height)) }
            let minX = max(0, Int((pts.map(\.x).min()! - radius).rounded(.down))), maxX = min(width - 1, Int((pts.map(\.x).max()! + radius).rounded(.up)))
            let minY = max(0, Int((pts.map(\.y).min()! - radius).rounded(.down))), maxY = min(height - 1, Int((pts.map(\.y).max()! + radius).rounded(.up)))
            guard minX <= maxX, minY <= maxY else { continue }
            let bw = maxX - minX + 1
            var own = [Double](repeating: 0, count: bw * (maxY - minY + 1))
            // a dab's radius: the stroke's, scaled by the pen pressure there (20% light ... 100% full); a stroke with no pressure is full
            func radiusAt(_ pressure: Double?) -> Double {
                guard let pressure, pressure.isFinite else { return radius }
                return max(0.5, radius * (0.2 + 0.8 * min(max(pressure, 0), 1)))
            }
            func stamp(_ c: SIMD2<Double>, _ r: Double) {
                let x0 = max(minX, Int((c.x - r).rounded(.down))), x1 = min(maxX, Int((c.x + r).rounded(.up)))
                let y0 = max(minY, Int((c.y - r).rounded(.down))), y1 = min(maxY, Int((c.y + r).rounded(.up)))
                guard x0 <= x1, y0 <= y1 else { return }
                for y in y0...y1 { for x in x0...x1 {
                    let d = ((Double(x) + 0.5 - c.x) * (Double(x) + 0.5 - c.x) + (Double(y) + 0.5 - c.y) * (Double(y) + 0.5 - c.y)).squareRoot()
                    let a = dab(d, radius: r, softness: stroke.softness) * flow
                    let i = (y - minY) * bw + (x - minX)
                    if a > own[i] { own[i] = a }
                } }
            }
            let spacing = max(0.5, radius * 0.15)
            let pressure = stroke.pressures
            stamp(pts[0], radiusAt(pressure?.first))
            for k in 1..<max(pts.count, 1) {
                let a = pts[k - 1], b = pts[k], len = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
                let steps = max(1, Int((len / spacing).rounded(.up)))
                for s in 1...steps {
                    let t = Double(s) / Double(steps)
                    // the pressure runs along the segment from one point's to the next
                    let p: Double? = pressure.map { $0[k - 1] + ($0[k] - $0[k - 1]) * t }
                    stamp(a + (b - a) * t, radiusAt(p))
                }
            }
            for y in minY...maxY { for x in minX...maxX {
                let s = own[(y - minY) * bw + (x - minX)]
                guard s > 0 else { continue }
                let i = y * width + x
                layer[i] = stroke.erase ? layer[i] * (1 - s) : layer[i] + (1 - layer[i]) * s
            } }
        }
        return MaskRaster(id: id, width: width, height: height, pixels: layer.map { UInt8(min(max(($0 * 255).rounded(), 0), 255)) })
    }
}
