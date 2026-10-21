// Method: film halation: light from bright highlights scatters back from the film base and exposes the emulsion again as a soft, warm glow around them. The picture's
// highlights (the soft luminance knee of `Bloom.bright`) are blurred widely (`Blur`) and added back, tinted: out = rgb + strength * tint * blur(bright(rgb)). The
// tint is an OkLab hue as a per-channel gain (`LiftGammaGain.tint`), scaled so its largest channel is 1; the default hue is red-orange. Light only goes up and a picture
// with nothing above the knee is untouched. Strength 0 is the identity.

import Foundation

public enum Halation {
    /// The glow's per-channel colour for a hue in degrees, largest channel 1.
    public static func tint(hueDegrees: Double) -> SIMD3<Double> {
        let g = LiftGammaGain.tint(hueDegrees: hueDegrees, strength: 1)
        let m = max(g.x, g.y, g.z)
        return m > 0 ? g / m : SIMD3(repeating: 1)
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, strength: Double, radius: Int, tint: SIMD3<Double>) -> [SIMD3<Double>] {
        guard strength != 0 else { return rgb }
        let glow = Blur.apply(rgb.map { Bloom.bright($0) }, width: width, height: height, radius: radius)
        return rgb.indices.map { rgb[$0] + strength * tint * glow[$0] }
    }
}
