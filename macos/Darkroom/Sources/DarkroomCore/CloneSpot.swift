// Method: spot retouching by frequency separation (the retoucher's heal: the low frequencies of the destination are kept, the detail of the source is brought in). A circular
// spot at the destination (centre dx, dy as fractions of the frame, radius a fraction of the frame height, feathered over `feather` of it) is replaced by the picture at an offset
// (the source centre minus the destination centre, in whole pixels). With B the picture's blur (`Blur`, the radius following the spot's), clone = rgb(q) and heal = B(p) + rgb(q) -
// B(q) at the source position q = p + offset, the pixel becomes mix(clone, heal, `heal`), weighted by amount x (1 - smoothstep(R (1 - feather), R, distance)). Heal 0 is a plain clone,
// heal 1 matches the surroundings' light and colour. Amount 0 is the identity. Reads are clamped at the frame edge.

import Foundation

public enum CloneSpot {
    public struct Spot: Sendable, Equatable {
        public var srcX = 0.3, srcY = 0.5, dstX = 0.6, dstY = 0.5, radius = 0.06, feather = 0.5, heal = 1.0, amount = 0.0
        public init() {}
        public init(values v: [String: Double]) {
            srcX = v["src_x"] ?? 0.3; srcY = v["src_y"] ?? 0.5; dstX = v["dst_x"] ?? 0.6; dstY = v["dst_y"] ?? 0.5
            radius = v["radius"] ?? 0.06; feather = v["feather"] ?? 0.5; heal = v["heal"] ?? 1; amount = v["amount"] ?? 0
        }
        /// The offset to the source, in pixels, and the spot radius and centre in pixels.
        public func geometry(width: Int, height: Int) -> (offset: SIMD2<Int>, centre: SIMD2<Double>, radius: Double) {
            let o = SIMD2(Int(((srcX - dstX) * Double(width - 1)).rounded()), Int(((srcY - dstY) * Double(height - 1)).rounded()))
            return (o, SIMD2(dstX * Double(width - 1), dstY * Double(height - 1)), max(radius * Double(height), 1))
        }
        public func blurRadius(height: Int) -> Double { Blur.radius(px: radius * Double(height)) }
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, spot: Spot) -> [SIMD3<Double>] {
        guard spot.amount != 0 else { return rgb }
        let g = spot.geometry(width: width, height: height)
        let blurred = Blur.apply(rgb, width: width, height: height, radius: spot.blurRadius(height: height))
        func at(_ x: Int, _ y: Int) -> Int { min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1) }
        return rgb.indices.map { i in
            let x = i % width, y = i / width
            let wgt = spot.amount * (1 - ColorCommon.smoothstep(g.radius * (1 - spot.feather), g.radius, hypot(Double(x) - g.centre.x, Double(y) - g.centre.y)))
            guard wgt > 0 else { return rgb[i] }
            let q = at(x + g.offset.x, y + g.offset.y)
            let clone = rgb[q], heal = blurred[i] + rgb[q] - blurred[q]
            return rgb[i] + wgt * (clone + spot.heal * (heal - clone) - rgb[i])
        }
    }
}
