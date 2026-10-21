// Rebuilds the colour of fully clipped pixels from nearby reliable colour (checkpoint A2).
//
// For each clipped pixel: look outwards at growing radii for source pixels (weights from
// HighlightSources). At the first radius with enough support, take their weighted average chroma
// (each pixel scaled to mean 1, so only the colour is averaged, not the brightness). Then blend the
// clip neutral towards that colour by how much support there was. With little or no support, the
// result is neutral white, so a blown sky between bare branches comes out white, not coloured.
//
// A window that runs off the picture reads the nearest edge pixel, like every neighbourhood filter here.
//
// Only fully clipped pixels change here. Partly clipped ones are A3. Written from this description;
// LightCraft's crates/raw/src/highlight.rs does the same job with a coarse-to-fine pyramid, which
// this is not.

import Foundation

public enum HighlightRebuild {
    /// Search radii in pixels, smallest first.
    public static let radii = [2, 4, 8, 16]
    /// Support (weighted share of the window) needed to take an estimate at a radius.
    public static let supportMin = 0.05
    /// Support at which the estimate is used at full strength; below it the result fades to neutral.
    public static let supportFull = 0.25

    public static func rebuild(_ pixels: [SIMD3<Double>], width: Int, height: Int, clip: Double = 1) -> [SIMD3<Double>] {
        precondition(pixels.count == width * height, "pixel count must match width * height")
        let weights = HighlightSources.weights(pixels, width: width, height: height, clip: clip)
        var out = pixels
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let p = pixels[i]
                let clipped = [p.x >= clip, p.y >= clip, p.z >= clip]
                let lost = clipped.filter { $0 }.count
                guard lost > 0 else { continue }
                let (chroma, support) = estimate(pixels, weights, width: width, height: height, x: x, y: y)
                let f = HighlightSources.ramp(support, from: 0, to: supportFull)
                if lost == 3 {
                    let neutral = SIMD3(repeating: clip)
                    out[i] = neutral + (chroma * clip - neutral) * f
                } else {
                    out[i] = partlyClipped(p, clipped: clipped, chroma: chroma, fade: f, clip: clip)
                }
            }
        }
        return out
    }

    /// `rebuild`, blended with the picture: `strength` 0 is the picture, 1 the full rebuild.
    public static func apply(_ pixels: [SIMD3<Double>], width: Int, height: Int, clip: Double, strength: Double) -> [SIMD3<Double>] {
        let s = strength.isFinite ? min(max(strength, 0), 1) : 0
        guard s > 0, clip > 0, clip.isFinite else { return pixels }
        let rebuilt = rebuild(pixels, width: width, height: height, clip: clip)
        return zip(pixels, rebuilt).map { $0 + ($1 - $0) * s }
    }

    /// A partly clipped pixel (A3). Unclipped channels keep their values. Each clipped channel takes
    /// the level the estimated colour gives it, read off the unclipped channels, never below clip,
    /// and scaled by `fade` (support), so with no support the clipped channels stay at clip.
    static func partlyClipped(_ p: SIMD3<Double>, clipped: [Bool], chroma: SIMD3<Double>, fade: Double, clip: Double) -> SIMD3<Double> {
        let keep = (0..<3).filter { !clipped[$0] }
        let lost = (0..<3).filter { clipped[$0] }
        let level = keep.map { p[$0] }.reduce(0, +) / Double(keep.count)
        let eMean = keep.map { chroma[$0] }.reduce(0, +) / Double(keep.count)
        var out = p
        for c in lost {
            let candidate = eMean > 0 ? level * chroma[c] / eMean : clip
            out[c] = clip + max(candidate - clip, 0) * fade
        }
        return out
    }

    /// Mean-1 chroma from the nearest radius with enough support, and that support. Returns the
    /// neutral and zero support when no radius has enough.
    static func estimate(_ pixels: [SIMD3<Double>], _ weights: [Double], width: Int, height: Int, x: Int, y: Int) -> (SIMD3<Double>, Double) {
        // a window that runs off the picture reads the nearest edge pixel there, as every neighbourhood filter in this engine does (Plane.at,
        // the box and guided filters), so the GPU's box filter and this agree exactly at the border
        func at(_ xx: Int, _ yy: Int) -> Int { min(max(yy, 0), height - 1) * width + min(max(xx, 0), width - 1) }
        for r in radii {
            var sum = SIMD3<Double>.zero
            var wsum = 0.0
            for yy in (y - r)...(y + r) {
                for xx in (x - r)...(x + r) {
                    let j = at(xx, yy)
                    let w = weights[j]
                    guard w > 0 else { continue }
                    let p = pixels[j]
                    let mean = (p.x + p.y + p.z) / 3
                    guard mean > 0 else { continue }
                    sum += (p / mean) * w
                    wsum += w
                }
            }
            let area = Double((2 * r + 1) * (2 * r + 1))
            let support = wsum / area
            if support >= supportMin, wsum > 0 {
                let c = sum / wsum
                return (c / ((c.x + c.y + c.z) / 3), support)
            }
        }
        return (SIMD3(repeating: 1), 0)
    }
}
