// Method: a soft shoulder on scene luminance. Below a knee (a fraction of the chosen white) light is untouched; above it the excess is compressed with
// tanh toward the white, Y' = K + (W - K) tanh((Y - K) / (W - K)) with K = knee * W, which is continuous with slope 1 at the knee and never reaches W.
// The colour is scaled by Y'/Y (hue and ratios kept), mixed in by `amount`: 0 is the identity. A luminance of 0 or less is left as it is.
// The tanh argument is capped at 20 (tanh is 1 there to machine precision) so a GPU float cannot overflow inside it.

import Foundation

public enum HighlightRolloff {
    public static func compress(_ y: Double, white w: Double, knee: Double) -> Double {
        let k = knee * w
        guard y > k else { return y }
        return k + (w - k) * tanh(min((y - k) / (w - k), 20))
    }

    public static func apply(_ rgb: SIMD3<Double>, white: Double, knee: Double, amount: Double) -> SIMD3<Double> {
        let y = ColorCommon.luminance(rgb)
        guard y > 0, y.isFinite else { return rgb }
        let s = 1 + amount * (compress(y, white: white, knee: knee) / y - 1)
        return rgb * s
    }
}
