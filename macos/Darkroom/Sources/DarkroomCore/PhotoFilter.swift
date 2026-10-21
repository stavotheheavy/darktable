// Method: a coloured photographic filter (the Wratten-style warming and cooling filters, and Photoshop's Photo Filter): the scene light is multiplied by the
// filter's colour, mixed in by `density`, and the result is rescaled so the pixel keeps its original luminance (`preserve` 1) or not (0), so the filter changes
// colour and not brightness. The filter colour is an OkLab chroma at a hue, as the per-channel gain `LiftGammaGain.tint` gives. Density 0 is the identity.

import Foundation

public enum PhotoFilter {
    public static func apply(_ rgb: SIMD3<Double>, hueDegrees: Double, density: Double, preserve: Double) -> SIMD3<Double> {
        let gain = LiftGammaGain.tint(hueDegrees: hueDegrees, strength: 1)
        let mixed = SIMD3(repeating: 1) + (gain - SIMD3(repeating: 1)) * density
        let filtered = rgb * mixed
        let before = ColorCommon.luminance(rgb), after = ColorCommon.luminance(filtered)
        guard after > 0, before > 0 else { return filtered }
        let k = 1 + preserve * (before / after - 1)
        return filtered * k
    }
}
