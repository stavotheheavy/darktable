// Method: film-like grain as lattice value noise (a hashed random value at each lattice point, blended between points with a smoothstep: the
// value-noise construction of K. Perlin and of Ebert et al., "Texturing and Modeling"), added to the display-encoded value with a weight that
// peaks in the midtones, 4e(1 - e), as real grain is least visible in pure black and white. The same noise goes on all three channels, so the grain
// is neutral. The noise is a pure function of the pixel position in the frame, the lattice spacing in pixels and a seed, so a tile of the frame
// gets the very same grain as the whole frame, and a render is repeatable.
//
// out_e = e + amplitude * strength * 4e(1 - e) * n, n in -1...1, e clamped to 0...1; strength 0 is the identity.

import Foundation

public enum Grain {
    /// The grain at full strength moves a mid-grey by this much of the encoded range.
    public static let amplitude = 0.15

    /// A hashed value in -1...1 for lattice point (x, y) and a seed (an integer hash with 32-bit wraparound).
    public static func lattice(_ x: Int32, _ y: Int32, seed: UInt32) -> Double {
        var h = UInt32(bitPattern: x) &* 374761393 &+ UInt32(bitPattern: y) &* 668265263 &+ seed &* 2246822519
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Double(h) / 4294967295.0 * 2 - 1
    }

    /// Value noise at (x, y) in pixels for lattice spacing `size` pixels (0.5 or more).
    public static func noise(x: Double, y: Double, size: Double, seed: UInt32) -> Double {
        let s = max(size, 0.5)
        let u = x / s, v = y / s
        let iu = u.rounded(.down), iv = v.rounded(.down)
        let fu = ColorCommon.smoothstep(0, 1, u - iu), fv = ColorCommon.smoothstep(0, 1, v - iv)
        let x0 = Int32(truncatingIfNeeded: Int(iu)), y0 = Int32(truncatingIfNeeded: Int(iv))
        let a = lattice(x0, y0, seed: seed), b = lattice(x0 &+ 1, y0, seed: seed)
        let c = lattice(x0, y0 &+ 1, seed: seed), d = lattice(x0 &+ 1, y0 &+ 1, seed: seed)
        return (a * (1 - fu) + b * fu) * (1 - fv) + (c * (1 - fu) + d * fu) * fv
    }

    public static func apply(_ rgb: SIMD3<Double>, x: Int, y: Int, strength: Double, size: Double, seed: UInt32) -> SIMD3<Double> {
        guard strength != 0 else { return rgb }
        let n = noise(x: Double(x), y: Double(y), size: size, seed: seed)
        func channel(_ v: Double) -> Double {
            let e = v.isNaN ? 0 : Transfer.linearToSRGB(min(max(v, 0), 1))
            return Transfer.srgbToLinear(min(max(e + amplitude * strength * 4 * e * (1 - e) * n, 0), 1))
        }
        return SIMD3(channel(rgb.x), channel(rgb.y), channel(rgb.z))
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, strength: Double, size: Double, seed: UInt32) -> [SIMD3<Double>] {
        guard strength != 0 else { return rgb }
        var out = rgb
        for y in 0..<height { for x in 0..<width { out[y * width + x] = apply(rgb[y * width + x], x: x, y: y, strength: strength, size: size, seed: seed) } }
        return out
    }
}
