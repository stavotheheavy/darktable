// The global tone map: scene luminance to display-linear luminance.
//
// Ported to Swift from `ToneMap::hdr` in LightCraft's `lightcraft-pipeline`
// (crates/pipeline/src/tone.rs, https://github.com/storytold/lightcraft at d999e38; MIT OR
// Apache-2.0, Copyright (c) 2026 ArtCraft Team and the LightCraft contributors). Modified: Swift,
// Double precision table, only the scene-referred path. See THIRD-PARTY.md.
//
// Built in the log domain around middle grey (0.18): contrast scales log-exposure about grey,
// whites move the shoulder (white point), blacks move the toe. The shoulder is an extended
// Reinhard curve, y (1 + y / w^2) / (1 + y), so highlights roll off instead of clipping.

import Foundation

public struct ToneMap: Sendable {
    public static let grey = 0.18
    /// The table spans `minEV...maxEV` around grey in `tableSize` steps.
    public static let minEV = -14.0
    public static let maxEV = 10.0
    public static let tableSize = 4096
    /// EV over grey where an HDR render starts lifting highlights past SDR white.
    private static let hdrFromEV = 1.5

    public private(set) var table: [Double]

    /// `contrast`, `whites`, `blacks` in -100...100. `peak` is linear with SDR white = 1 (1 = SDR).
    public init(contrast: Double = 0, whites: Double = 0, blacks: Double = 0, peak: Double = 1) {
        let peak = peak.isFinite ? max(peak, 1) : 1
        let c = contrast / 100
        let slope = c >= 0 ? 1 + 0.55 * c : 1 + 0.4 * c
        // scene luminance (after contrast) that maps to display 1.0
        let whiteEV = 2.9 - 1.6 * (whites / 100)
        let wl = Self.grey * pow(2, whiteEV)
        let pre = 1 + Self.grey / wl  // keeps grey near grey
        let b = blacks / 100
        var t = [Double](repeating: 0, count: Self.tableSize)
        for i in 0..<Self.tableSize {
            let ev = Self.minEV + (Self.maxEV - Self.minEV) * Double(i) / Double(Self.tableSize - 1)
            let y = Self.grey * pow(2, ev * slope) * pre
            var o = min(y * (1 + y / (wl * wl)) / (1 + y), 1)
            if b < 0 {
                // soft knee max(0, o - k), renormalised so 1 stays 1
                let k = -b * 0.035
                let e = 0.004
                func soft(_ v: Double) -> Double { ((v - k) + ((v - k) * (v - k) + e * e).squareRoot()) * 0.5 }
                o = (soft(o) - soft(0)) / (soft(1) - soft(0))
            } else if b > 0 {
                let k = b * 0.03
                o = k + (1 - k) * o
            }
            if peak > 1 {
                let top = max(whiteEV + log2(peak) + 1, Self.hdrFromEV + 0.5)
                o += (peak - 1) * Self.smooth(Self.hdrFromEV, top, ev * slope)
            }
            t[i] = min(max(o, 0), peak)
        }
        table = t
    }

    /// Scene luminance to display-linear luminance.
    public func apply(_ y: Double) -> Double {
        if y <= 0 { return 0 }
        let ev = log2(y / Self.grey)
        let f = min(max((ev - Self.minEV) / (Self.maxEV - Self.minEV), 0), 1) * Double(Self.tableSize - 1)
        let i = min(Int(f), Self.tableSize - 2)
        let t = f - Double(i)
        let v = table[i] + (table[i + 1] - table[i]) * t
        return ev < Self.minEV ? v * (y / (Self.grey * pow(2, Self.minEV))) : v
    }

    private static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
