// Method: distance in the ellipse's own axes (the point rotated into the ellipse frame, scaled by the radii), faded with a smoothstep over the inner `feather` fraction of the radius (Hermite smoothstep, as Mask.ramp).

import Foundation

/// Ellipse / radial mask (kind 2). Parameters, in order: [cx, cy, rx, ry, rotationRadians, feather].
/// cx, cy are fractions of width and height; rx, ry are fractions of the frame diagonal.
public enum MaskEllipse {
    /// The blend keys' values as the parameter list the kernel reads.
    public static func params(_ blend: [String: Double]) -> [Double] {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        return [clamp(blend["mask_cx"] ?? 0.5, 0, 1),
                clamp(blend["mask_cy"] ?? 0.5, 0, 1),
                clamp(blend["mask_rx"] ?? 0.25, 1e-4, 2),
                clamp(blend["mask_ry"] ?? 0.25, 1e-4, 2),
                (blend["mask_rotation"] ?? 0) * Double.pi / 180,
                clamp(blend["mask_feather"] ?? 0.2, 0, 1)]
    }

    public static func alpha(p: [Double], x: Double, y: Double, width: Double, height: Double) -> Double {
        let diag = hypot(width, height)
        let dx = x - p[0] * width, dy = y - p[1] * height
        let c = cos(p[4]), s = sin(p[4])
        let u = dx * c + dy * s
        let v = -dx * s + dy * c
        var r = hypot(u / (p[2] * diag), v / (p[3] * diag))
        if !r.isFinite { r = .infinity }
        return 1 - Mask.ramp(1 - p[5], 1, r)
    }
}
