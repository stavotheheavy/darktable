// Method: the clipping warning every raw editor shows: pixels the display cannot tell apart from pure white or pure black are
// painted red (blown) or blue (crushed). A pixel is blown when any channel encodes to 255, crushed when any channel encodes to
// 0 (blown wins), the same rule the histogram's shadows and highlights readout counts, so the two always agree. The tint is
// a 85% mix toward the warning colour, so the structure under it still shows. Display-only: never part of an export.

import Foundation

public enum Clipping {
    /// Linear working-space values at the rounding boundaries of the 8-bit sRGB encode: 254.5 / 255 and 0.5 / 255.
    public static let blownFrom = Transfer.srgbToLinear(254.5 / 255)
    public static let crushedTo = Transfer.srgbToLinear(0.5 / 255)
    public static let mix = 0.85
    public static let blownColour = SIMD3<Double>(1, 0.1, 0.1)
    public static let crushedColour = SIMD3<Double>(0.15, 0.35, 1)

    public enum State: Sendable { case fine, blown, crushed }

    public static func state(_ rgb: SIMD3<Double>) -> State {
        if max(rgb.x, rgb.y, rgb.z) >= blownFrom { return .blown }
        if min(rgb.x, rgb.y, rgb.z) <= crushedTo { return .crushed }
        return .fine
    }

    public static func tint(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        switch state(rgb) {
        case .fine: return rgb
        case .blown: return rgb + (blownColour - rgb) * mix
        case .crushed: return rgb + (crushedColour - rgb) * mix
        }
    }
}
