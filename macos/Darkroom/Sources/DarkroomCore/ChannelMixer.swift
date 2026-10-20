// Method: 3x3 matrix on linear working RGB, one row per output channel; the row form is Apple's CIColorMatrix (Core Image documentation), with no clamp.

/// The channel mixer: each output channel is a weighted sum of the three input channels. The identity rows
/// leave the image unchanged. Nothing is normalised or clamped, so values past white and below black keep
/// their size and sign.
public enum ChannelMixer {
    /// `rows` = [[red_r, red_g, red_b], [green_r, green_g, green_b], [blue_r, blue_g, blue_b]]
    public static func apply(_ rgb: SIMD3<Double>, rows: [[Double]]) -> SIMD3<Double> {
        precondition(rows.count == 3 && rows.allSatisfy { $0.count == 3 }, "channel mixer needs a 3x3 matrix")
        return SIMD3(rows[0][0] * rgb.x + rows[0][1] * rgb.y + rows[0][2] * rgb.z,
                     rows[1][0] * rgb.x + rows[1][1] * rgb.y + rows[1][2] * rgb.z,
                     rows[2][0] * rgb.x + rows[2][1] * rgb.y + rows[2][2] * rgb.z)
    }
}
