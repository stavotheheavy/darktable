// Method: luminance range mask: the weight is 1 inside a window of s = sqrt(Y) (Y the Rec.709 luminance of the working-space colour, the square-root domain the S5 detail modules use), with smoothstep ramps (Hermite, as in darktable-style parametric masks) of width feather * (high - low) / 2 inside each end of the window.

import Foundation

public enum MaskLuminance {
    /// `[low, high, feather]` from `mask_low` (0.2), `mask_high` (0.8), `mask_feather` (0.25): low and high clamped to 0...4
    /// and swapped if low > high, feather clamped to 0...1.
    public static func params(_ blend: [String: Double]) -> [Double] {
        var low = min(max(blend["mask_low"] ?? 0.2, 0), 4)
        var high = min(max(blend["mask_high"] ?? 0.8, 0), 4)
        if low > high { swap(&low, &high) }
        return [low, high, min(max(blend["mask_feather"] ?? 0.25, 0), 1)]
    }

    public static func alpha(p: [Double], rgb: SIMD3<Double>) -> Double {
        let y = ColorCommon.luminance(rgb)
        let s = y.isFinite ? sqrt(max(y, 0)) : 0
        let low = p[0], high = p[1]
        let fw = p[2] * (high - low) / 2
        return Mask.ramp(low, low + fw, s) * (1 - Mask.ramp(high - fw, high, s))
    }
}
