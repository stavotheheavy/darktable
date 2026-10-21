// Method: the inversion of a scanned colour negative from its density. A negative transmits T = 10^-D, and the density D grows with the log of the
// light that exposed it (D = gamma_n * log10(E) + D0), so the exposure is recovered per channel as E = (Dmin / T)^(1 / gamma_n) where Dmin is the
// transmission of the unexposed film base (its orange mask) measured on the scan. This is the standard negative-to-positive relation of film
// densitometry (the Hurter-Driffield characteristic curve, in its straight-line region).
//
// Settings: `dmin` the film base colour (linear, per channel, 0...1), `gamma` the exponent 1 / gamma_n, `exposure` a gain on the result and
// `black` an offset taken off it. The output is scene-linear light, never below 0; T is held at 1e-4 or more so a black scan value stays finite.

import Foundation

public enum NegativeFilm {
    public static let floor = 1e-4

    public static func apply(_ rgb: SIMD3<Double>, dmin: SIMD3<Double>, gamma: Double, exposure: Double, black: Double) -> SIMD3<Double> {
        func channel(_ v: Double, _ d: Double) -> Double {
            let t = max(v.isNaN ? 0 : v, floor)
            return max(exposure * pow(d / t, gamma) - black, 0)
        }
        return SIMD3(channel(rgb.x, dmin.x), channel(rgb.y, dmin.y), channel(rgb.z, dmin.z))
    }
}
