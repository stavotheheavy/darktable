// Method: a scene-referred zone exposure. The picture's log luminance is split into a smooth base and the detail on top,
// the base is smoothed edge-aware with a guided filter (K. He, J. Sun, X. Tang, "Guided Image Filtering", ECCV 2010), and an
// exposure change in stops is looked up from the BASE alone, so the gain follows the broad brightness of a region and leaves
// the texture on top of it untouched (the base and detail split of F. Durand and J. Dorsey, "Fast Bilateral Filtering for the
// Display of High-Dynamic-Range Images", SIGGRAPH 2002, with the guided filter as the smoother). The gain is a multiplication
// of all three channels, so colour ratios are kept. Ten zones, one per stop from -7 to +2 EV over middle grey, blend with a
// raised cosine so their weights always sum to one: the same change on every zone is exactly a global exposure.
//
// Settings: ten zone changes `z_*` in EV, four semantic controls that spread over zones (shadows, highlights, blacks, whites),
// and `scale`, the smoothing radius as a fraction of the picture's long side. All zero is the identity.

import Foundation

public enum ZoneExposure {
    /// The zone centres, in EV over middle grey (0.18).
    public static let centres: [Int] = Array(-7...2)
    public static let grey = 0.18
    /// The variance, in EV squared, an edge in the log luminance needs to be kept by the base: edges over about half a stop stay sharp.
    public static let eps = 0.25
    /// The longest smoothing radius, in pixels (the box filters take their weights as a uniform of fixed size).
    public static let maxRadius = 400
    public static let defaultScale = 0.04
    /// Log luminance never goes below this, so black is a finite zone.
    static let minLuminance = 1e-6

    /// How the semantic controls spread over the ten zones (one weight per zone, -7 to +2).
    static let shadowsWeights: [Double] = [1, 1, 1, 1, 0.75, 0.25, 0, 0, 0, 0]
    static let highlightsWeights: [Double] = [0, 0, 0, 0, 0, 0, 0, 0.25, 0.75, 1]
    static let blacksWeights: [Double] = [1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
    static let whitesWeights: [Double] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1]

    public struct Settings: Sendable, Equatable {
        /// Zone changes in EV, index 0 is zone -7 and index 9 is zone +2.
        public var zones: [Double]
        public var shadows = 0.0, highlights = 0.0, blacks = 0.0, whites = 0.0
        public var scale = ZoneExposure.defaultScale

        public init(zones: [Double] = [Double](repeating: 0, count: 10), shadows: Double = 0, highlights: Double = 0,
                    blacks: Double = 0, whites: Double = 0, scale: Double = ZoneExposure.defaultScale) {
            self.zones = zones
            self.shadows = shadows; self.highlights = highlights; self.blacks = blacks; self.whites = whites
            self.scale = scale
        }

        /// From a module's values: `z_m7`...`z_m1`, `z_0`, `z_p1`, `z_p2`, `shadows`, `highlights`, `blacks`, `whites`, `scale`.
        public init(values v: [String: Double]) {
            let names = ["z_m7", "z_m6", "z_m5", "z_m4", "z_m3", "z_m2", "z_m1", "z_0", "z_p1", "z_p2"]
            self.init(zones: names.map { v[$0] ?? 0 }, shadows: v["shadows"] ?? 0, highlights: v["highlights"] ?? 0,
                      blacks: v["blacks"] ?? 0, whites: v["whites"] ?? 0, scale: v["scale"] ?? ZoneExposure.defaultScale)
        }

        /// The change in EV at each zone once the semantic controls are added in.
        public var zoneEVs: [Double] {
            (0..<10).map { k in
                let e = zones[k] + shadows * ZoneExposure.shadowsWeights[k] + highlights * ZoneExposure.highlightsWeights[k]
                    + blacks * ZoneExposure.blacksWeights[k] + whites * ZoneExposure.whitesWeights[k]
                return e.isFinite ? min(max(e, -8), 8) : 0
            }
        }

        public var isIdentity: Bool { zoneEVs.allSatisfy { $0 == 0 } }
    }

    /// The weight of each of the ten zones at base brightness `b` (EV over grey). They sum to one.
    public static func weights(_ b: Double) -> [Double] {
        let c = min(max(b.isFinite ? b : 0, -7), 2)
        var w = [Double](repeating: 0, count: 10)
        let k = min(Int(floor(c)), 1)
        let f = c - Double(k)
        let upper = 0.5 * (1 - cos(Double.pi * f))
        w[k + 7] = 1 - upper
        w[k + 8] = upper
        return w
    }

    /// The exposure change in EV for base brightness `b`, from the ten zone changes.
    public static func gain(base b: Double, evs: [Double]) -> Double {
        let w = weights(b)
        var g = 0.0
        for k in 0..<10 where w[k] != 0 { g += evs[k] * w[k] }
        return g
    }

    /// The smoothing radius in pixels for a frame whose long side is `longSide`.
    public static func radius(scale: Double, longSide: Int) -> Int {
        let s = scale.isFinite ? min(max(scale, 0.005), 0.2) : defaultScale
        return min(max(Int((s * Double(longSide)).rounded()), 1), maxRadius)
    }

    /// Log luminance in EV over grey of one pixel (Rec.709 weights, the working space's).
    public static func logLuminance(_ p: SIMD3<Double>) -> Double {
        log2(max(ColorCommon.luminance(p), minLuminance) / grey)
    }

    /// The whole module on the CPU: the base is the guided filter of the log luminance guided by itself.
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, settings: Settings) -> [SIMD3<Double>] {
        guard !settings.isIdentity else { return rgb }
        let z = Plane(width: width, height: height, values: rgb.map { logLuminance($0) })
        let r = radius(scale: settings.scale, longSide: max(width, height))
        let base = Filters.guided(guide: z, input: z, radius: r, eps: eps)
        return apply(rgb, base: base, evs: settings.zoneEVs)
    }

    /// The gain stage alone, from a given base (tests swap the base to prove it matters).
    public static func apply(_ rgb: [SIMD3<Double>], base: Plane, evs: [Double]) -> [SIMD3<Double>] {
        rgb.enumerated().map { i, p in p * pow(2, gain(base: base.values[i], evs: evs)) }
    }
}
