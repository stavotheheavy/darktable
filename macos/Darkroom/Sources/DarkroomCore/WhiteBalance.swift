// White balance and clip-aware highlight handling, in linear camera RGB.
//
// Gains come from a colour temperature: an approximate blackbody colour per temperature (the
// published curve fit by Tanner Helland, 2012; the fit's formula only, code written here),
// normalized so 6500 K gives neutral gains. Tint is not modelled yet.
//
// Highlights: a channel that clipped at the sensor is limited to the lowest white-balanced clip
// level, then the gains are divided back out. The clipped area then comes out neutral instead of
// magenta or cyan once the gains are applied. The idea is the same as LightCraft's `clip_neutral`
// (crates/raw/src/highlight.rs), rewritten from this comment; the rest of that module (rebuilding
// partly clipped channels) is not ported.

import Foundation

public enum WhiteBalance {
    /// The reference temperature: its gains are exactly neutral.
    public static let neutralKelvin = 6500.0

    /// Blackbody-like RGB for a temperature in kelvin, clamped to 1000...40000 K. Each channel is
    /// in 0...1 (gamma encoded, as the fit was made in that space).
    static func blackbody(kelvin: Double) -> SIMD3<Double> {
        let t = min(max(kelvin, 1000), 40000) / 100
        let r = t <= 66 ? 255.0 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66
            ? 99.4708025861 * log(t) - 161.1195681661
            : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b: Double
        if t >= 66 {
            b = 255
        } else if t <= 19 {
            b = 0
        } else {
            b = 138.5177312231 * log(t - 10) - 305.0447927307
        }
        return SIMD3(r, g, b).clamped(lower: 0, upper: 255) / 255
    }

    /// Gains that neutralize light of `kelvin`: the neutral reference divided by the light's colour,
    /// so warm light (low K) gets less red and more blue. Green is the anchor.
    /// `tint` in -150...150: positive adds green (removes magenta), negative adds magenta. It scales
    /// red and blue down by up to half, which leaves green as the anchor.
    public static func gains(kelvin: Double, tint: Double = 0) -> SIMD3<Double> {
        let light = blackbody(kelvin: kelvin)
        let neutral = blackbody(kelvin: neutralKelvin)
        let g = neutral / light
        let t = 1 - min(max(tint, -150), 150) / 300
        return SIMD3(g.x / g.y * t, 1, g.z / g.y * t)
    }

    /// Limits each channel at the lowest white-balanced clip level, then divides the gains back out,
    /// so a pixel that clipped comes out equal across channels after the gains are applied again.
    /// `clip` is the sensor clip level in normalized units (1.0 when the data is normalized).
    public static func clipNeutral(_ pixel: SIMD3<Double>, gains: SIMD3<Double>, clip: Double = 1) -> SIMD3<Double> {
        let limit = min(gains.x, gains.y, gains.z) * clip
        let balanced = pixel * gains
        return SIMD3(min(balanced.x, limit), min(balanced.y, limit), min(balanced.z, limit)) / gains
    }
}

public enum Exposure {
    /// Linear gain for an exposure change in stops (EV). +1 doubles, -1 halves.
    public static func gain(ev: Double) -> Double {
        pow(2, ev)
    }
}

extension SIMD3 where Scalar == Double {
    func clamped(lower: Double, upper: Double) -> SIMD3<Double> {
        SIMD3(Swift.min(Swift.max(x, lower), upper), Swift.min(Swift.max(y, lower), upper), Swift.min(Swift.max(z, lower), upper))
    }
}
