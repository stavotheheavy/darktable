// Method: the photographic negative: the complement of each channel's display-encoded value (the sRGB transfer curve of IEC 61966-2-1,
// `Transfer`), as a print from a negative or any editor's Invert shows it.
//
// Taking 1 - x on the linear value instead would turn middle grey (0.214 linear, 0.5 encoded) into 0.786 linear, a very light grey.
// On the encoded value middle grey stays middle grey, so the result reads as a negative of the photo, not as a washed-out one.

import Foundation

public enum Invert {
    /// Linear working-space RGB in, the same kind out. Each channel is clamped to 0...1 first: the negative of a value past white
    /// is black, and of a value below black is white. Applying it twice gives the input back on 0...1.
    public static func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(channel(rgb.x), channel(rgb.y), channel(rgb.z))
    }

    /// One channel. A NaN input is treated as black, so a bad pixel never spreads.
    static func channel(_ v: Double) -> Double {
        let x = v.isNaN ? 0 : min(max(v, 0), 1)
        return Transfer.srgbToLinear(1 - Transfer.linearToSRGB(x))
    }
}
