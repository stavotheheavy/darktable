// Method: a linear motion blur: every pixel becomes the mean of 2 L + 1 bilinear samples (`Remap.sample`, edges clamped) at one-pixel steps along a line of the given
// angle through it, from -L to +L, as a camera moving during the exposure smears the scene. Length 0 is the identity; angle 0 is horizontal, positive angles turn
// counter-clockwise on screen (toward the top).

import Foundation

public enum MotionBlur {
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, length: Int, angleDegrees: Double) -> [SIMD3<Double>] {
        guard length > 0 else { return rgb }
        let t = angleDegrees * .pi / 180, dx = cos(t), dy = -sin(t)
        var out = rgb
        for y in 0..<height {
            for x in 0..<width {
                var sum = SIMD3<Double>(repeating: 0)
                for k in -length...length {
                    let p = SIMD2(Double(x) + Double(k) * dx, Double(y) + Double(k) * dy)
                    for c in 0..<3 { sum[c] += Remap.sample(rgb, width: width, height: height, at: p, channel: c) }
                }
                out[y * width + x] = sum / Double(2 * length + 1)
            }
        }
        return out
    }
}
