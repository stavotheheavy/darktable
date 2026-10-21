// Method: bilinear resampling (the standard image warp: each output pixel reads the source at a computed position and blends the four surrounding pixels by
// their distances, positions clamped to the frame) with three position maps, all about the frame centre c = ((W-1)/2, (H-1)/2):
//  - radial lens distortion (D. C. Brown, "Close-range camera calibration", Photogrammetric Engineering 37, 1971): source = c + (p - c) (1 + k1 r^2 + k2 r^4),
//    r the distance from the centre in units of the half diagonal; k1 > 0 pulls the edges in (corrects barrel distortion), k1 < 0 pushes them out (pincushion);
//  - lateral chromatic aberration: the red and blue channels are scaled about the centre, source = c + (p - c) s with s = 1 + red or 1 + blue, green fixed, which
//    undoes the colour fringing a lens makes by magnifying each colour a little differently;
//  - keystone (a plane projective map): with u = (x - cx) / cx and v = (y - cy) / cy, w = 1 + kx u + ky v, source = c + (u / w, v / w) (cx, cy), the vertical and
//    horizontal perspective sliders.
// All three are the identity at zero settings (the source position is then exactly the output position, and the bilinear sample of an integer position is the pixel).

import Foundation

public enum Remap {
    public enum Kind: Sendable, Equatable {
        case distortion(k1: Double, k2: Double)
        case chromaticAberration(red: Double, blue: Double)
        case perspective(horizontal: Double, vertical: Double)
    }

    /// Where output pixel (x, y) reads channel `channel` (0 red, 1 green, 2 blue) from.
    public static func source(_ kind: Kind, x: Double, y: Double, width: Int, height: Int, channel: Int) -> SIMD2<Double> {
        let cx = Double(width - 1) / 2, cy = Double(height - 1) / 2
        switch kind {
        case .distortion(let k1, let k2):
            let norm = max(hypot(cx, cy), 1e-9)
            let u = (x - cx) / norm, v = (y - cy) / norm
            let r2 = u * u + v * v
            let f = 1 + k1 * r2 + k2 * r2 * r2
            return SIMD2(cx + (x - cx) * f, cy + (y - cy) * f)
        case .chromaticAberration(let red, let blue):
            let s = channel == 0 ? 1 + red : channel == 2 ? 1 + blue : 1
            return SIMD2(cx + (x - cx) * s, cy + (y - cy) * s)
        case .perspective(let kx, let ky):
            let u = cx > 0 ? (x - cx) / cx : 0, v = cy > 0 ? (y - cy) / cy : 0
            let w = 1 + kx * u + ky * v
            let d = abs(w) < 1e-6 ? 1e-6 : w
            return SIMD2(cx + (u / d) * cx, cy + (v / d) * cy)
        }
    }

    /// Bilinear sample of one channel at a position, clamped to the frame.
    public static func sample(_ rgb: [SIMD3<Double>], width: Int, height: Int, at p: SIMD2<Double>, channel: Int) -> Double {
        let x = min(max(p.x.isFinite ? p.x : 0, 0), Double(width - 1)), y = min(max(p.y.isFinite ? p.y : 0, 0), Double(height - 1))
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = x - Double(x0), fy = y - Double(y0)
        let a = rgb[y0 * width + x0][channel], b = rgb[y0 * width + x1][channel]
        let c = rgb[y1 * width + x0][channel], d = rgb[y1 * width + x1][channel]
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, kind: Kind) -> [SIMD3<Double>] {
        var out = rgb
        for y in 0..<height {
            for x in 0..<width {
                var px = SIMD3<Double>(repeating: 0)
                for c in 0..<3 {
                    px[c] = sample(rgb, width: width, height: height, at: source(kind, x: Double(x), y: Double(y), width: width, height: height, channel: c), channel: c)
                }
                out[y * width + x] = px
            }
        }
        return out
    }

    /// How far (in whole pixels, rounded up, plus 2 for the bilinear taps) any output pixel reads from its own position: the region a GPU kernel must be given.
    public static func reach(_ kind: Kind, width: Int, height: Int) -> Int {
        var worst = 0.0
        let nx = 16, ny = 16
        for j in 0...ny {
            for i in 0...nx {
                let x = Double(width - 1) * Double(i) / Double(nx), y = Double(height - 1) * Double(j) / Double(ny)
                for c in 0..<3 {
                    let p = source(kind, x: x, y: y, width: width, height: height, channel: c)
                    let q = SIMD2(min(max(p.x.isFinite ? p.x : 0, 0), Double(width - 1)), min(max(p.y.isFinite ? p.y : 0, 0), Double(height - 1)))
                    worst = max(worst, abs(q.x - x), abs(q.y - y))
                }
            }
        }
        return Int(worst.rounded(.up)) + 2
    }
}
