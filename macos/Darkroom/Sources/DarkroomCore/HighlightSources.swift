// Which pixels may lend their colour to a clipped neighbour (checkpoint A1 of the highlight rebuild).
//
// A weight of 0...1 per pixel:
// - dark content says nothing about a blown area's colour, so weight ramps from 0 at `sourceLo` of
//   the clip level to 1 at `sourceHi`
// - a pixel within `margin` of a clipped pixel is excluded: its channels were partly demosaiced from
//   clipped samples
// - a pixel on a strong edge (a neighbour more than a few stops away) fades to 0: edges mix two
//   surfaces and carry lens fringes
//
// Written from this description. LightCraft's crates/raw/src/highlight.rs uses the same three ideas
// with more machinery; see THIRD-PARTY.md.

import Foundation

public enum HighlightSources {
    /// Fractions of the clip level where a pixel starts and finishes counting as a source.
    public static let sourceLo = 0.25
    public static let sourceHi = 0.6
    /// Edge strength in stops (log2 of the brightest/darkest neighbour ratio): full weight up to
    /// `edgeLo`, none from `edgeHi`.
    public static let edgeLo = 0.15
    public static let edgeHi = 0.4
    /// Pixels this close (in Chebyshev distance) to a clipped pixel are excluded.
    public static let margin = 1

    /// Per-pixel source weights, row-major, for a `width` by `height` image in linear RGB where
    /// `clip` is the sensor clip level.
    public static func weights(_ pixels: [SIMD3<Double>], width: Int, height: Int, clip: Double = 1) -> [Double] {
        precondition(pixels.count == width * height, "pixel count must match width * height")
        let brightness = pixels.map { max($0.x, max($0.y, $0.z)) }
        let clipped = pixels.map { $0.x >= clip || $0.y >= clip || $0.z >= clip }
        var out = [Double](repeating: 0, count: pixels.count)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                if nearClipped(clipped, x: x, y: y, width: width, height: height) { continue }
                let level = brightness[i] / clip
                var w = ramp(level, from: sourceLo, to: sourceHi)
                if w == 0 { continue }
                w *= 1 - ramp(maxEdgeStops(brightness, x: x, y: y, width: width, height: height), from: edgeLo, to: edgeHi)
                out[i] = w
            }
        }
        return out
    }

    static func nearClipped(_ clipped: [Bool], x: Int, y: Int, width: Int, height: Int) -> Bool {
        for dy in -margin...margin {
            for dx in -margin...margin {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < width, ny < height, clipped[ny * width + nx] { return true }
            }
        }
        return false
    }

    /// Largest brightness step in stops against the 8 neighbours. Brightness is floored so black
    /// pixels don't read as infinite edges.
    static func maxEdgeStops(_ brightness: [Double], x: Int, y: Int, width: Int, height: Int) -> Double {
        let here = max(brightness[y * width + x], 1e-6)
        var worst = 0.0
        for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let there = max(brightness[ny * width + nx], 1e-6)
                worst = max(worst, abs(log2(here / there)))
            }
        }
        return worst
    }

    /// 0 at or below `from`, 1 at or above `to`, smoothstep in between.
    static func ramp(_ x: Double, from: Double, to: Double) -> Double {
        let t = min(max((x - from) / (to - from), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
