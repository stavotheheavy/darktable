// Method: linear interpolation between two whole-pixel results (first principles, no darktable source).

import Foundation

/// A gather window is whole pixels, but a slider that reaches it through the preview's scale factor is not: at 0.13 every radius up to about 8 px is a window of 1.
/// A window of radius r = n + f is the blend of the windows n and n + 1 by f, where the window 0 is the picture itself, so a radius under 1 fades the effect in from nothing
/// and every slider position gives a different picture. A whole radius runs once and is the integer result exactly.
public enum FractionalWindow {
    /// The whole part and the fraction of a radius; a radius that is not finite or not positive is 0 and 0.
    public static func split(_ r: Double) -> (n: Int, f: Double) {
        guard r.isFinite, r > 0 else { return (0, 0) }
        let n = Int(min(r, 1e6).rounded(.down))
        return (n, r - Double(n))
    }

    /// `run(k)` is the module at the whole radius k (k >= 1); `rgb` is its input.
    public static func apply(_ rgb: [SIMD3<Double>], radius r: Double, _ run: (Int) -> [SIMD3<Double>]) -> [SIMD3<Double>] {
        let (n, f) = split(r)
        let a = n >= 1 ? run(n) : rgb
        guard f > 1e-12 else { return a }
        let b = run(n + 1)
        return zip(a, b).map { $0 + f * ($1 - $0) }
    }
}
