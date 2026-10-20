// Method: linear ramp along a direction, the graduated-neutral-density mask; smoothstep band (Mask.ramp) centred on
// `position`, `feather` wide, both as fractions of the frame diagonal.
//   mask_angle degrees (0 = weight grows to the right, 90 = downward), mask_position 0...1, mask_feather 0...1.

import Foundation

public enum MaskGradient {
    /// [angle in radians, position 0...1, feather 0...1]; defaults 0, 0.5, 0.2. A non-finite value falls back to its default.
    public static func params(_ blend: [String: Double]) -> [Double] {
        func get(_ key: String, _ def: Double) -> Double {
            guard let v = blend[key], v.isFinite else { return def }
            return v
        }
        return [get("mask_angle", 0) * .pi / 180,
                min(max(get("mask_position", 0.5), 0), 1),
                min(max(get("mask_feather", 0.2), 0), 1)]
    }

    public static func alpha(p: [Double], x: Double, y: Double, width: Double, height: Double) -> Double {
        let d = hypot(width, height)
        let t = ((x - width / 2) * cos(p[0]) + (y - height / 2) * sin(p[0])) / d + 0.5
        return Mask.ramp(p[1] - p[2] / 2, p[1] + p[2] / 2, t)
    }
}
