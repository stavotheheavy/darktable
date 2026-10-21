// Method: a Purkinje-shift model of vision in dim light. Below a luminance range the eye's rods take over: colour fades and the scene reads
// blue-green. Where the scene luminance Y is low, the pixel is mixed toward a scotopic grey, a weighted sum favouring green and blue with a cool tint
// of unit luminance: out = rgb + w * (scotopic - rgb), w = strength * (1 - smoothstep(0.01, 0.25, Y)).
// The weights and tint are chosen from the shape of the scotopic luminous efficiency curve (peak near 507 nm, blue-green), a model, not a measured
// colour transform. Bright pixels (Y above 0.25) and strength 0 are untouched.

import Foundation

public enum LowLight {
    public static let lumaLow = 0.01, lumaHigh = 0.25
    /// The scotopic grey's channel weights (summing to 1) and the cool tint it is multiplied by.
    public static let scotopicWeights = SIMD3(0.10, 0.55, 0.35)
    public static let tintRaw = SIMD3(0.85, 0.97, 1.20)

    /// The tint scaled to unit luminance, so tinting changes colour and not brightness.
    public static var tint: SIMD3<Double> { tintRaw / ColorCommon.luminance(tintRaw) }

    public static func apply(_ rgb: SIMD3<Double>, strength: Double) -> SIMD3<Double> {
        let y = ColorCommon.luminance(rgb)
        let w = strength * (1 - ColorCommon.smoothstep(lumaLow, lumaHigh, y))
        guard w > 0 else { return rgb }
        let scotopic = (scotopicWeights.x * rgb.x + scotopicWeights.y * rgb.y + scotopicWeights.z * rgb.z) * tint
        return rgb + w * (scotopic - rgb)
    }
}
