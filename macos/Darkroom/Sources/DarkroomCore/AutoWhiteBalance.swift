// Method: Buchsbaum, G., "A spatial processor model for object colour perception", J. Franklin Inst. 310(1), 1980. Grey-world white balance, restricted to reliable pixels.

// Auto white balance: the scene's average colour is taken to be neutral, so the gains that make
// that average grey are the auto white balance. Clipped and near-black pixels are left out of the
// average, since their colour is not the light's colour.

public enum AutoWhiteBalance {
    /// Grey-world gains (green = 1) over the reliable pixels of a scene-linear image, row-major, width * height pixels.
    public static func gains(_ pixels: [SIMD3<Double>], width: Int, height: Int, clip: Double = 1) -> SIMD3<Double> {
        let neutral = SIMD3<Double>(1, 1, 1)
        guard !pixels.isEmpty, pixels.count == width * height else { return neutral }

        // reliable: no channel at the clip level, and not noise
        let ceiling = 0.95 * clip
        var sum = SIMD3<Double>(repeating: 0)
        var count = 0.0
        for p in pixels {
            let luminance = ColorCommon.luminance(p)
            guard p.max() < ceiling, luminance >= 0.02 else { continue }
            sum += p
            count += 1
        }
        guard count >= 0.01 * Double(pixels.count) else { return neutral }

        let mean = sum / count
        guard mean.min() > 1e-9 else { return neutral }
        return SIMD3(mean.y / mean.x, 1, mean.y / mean.z).clamped(lower: 0.25, upper: 4)
    }
}
