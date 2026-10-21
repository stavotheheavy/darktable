// Method: a radial blur about a centre point: every pixel becomes the mean of 2n + 1 bilinear samples (`Remap.sample`, edges clamped) taken along a short path through it,
// either scaling about the centre (zoom blur: a camera zoomed during the exposure) or rotating about it (spin blur: a rotating subject or a twisted camera). With n samples
// each side (`samples`, from the blur length), sample k of -n...n sits at fraction k / n of the extent: zoom scales by 1 + (k / n) z, spin rotates by (k / n) a. `amount` 0 is the identity; the zoom extent is z = 0.1 amount and
// the spin extent a = 10 degrees x amount. The centre is given as fractions of the frame.

import Foundation

public enum RadialBlur {
    /// The samples each side of the pixel: enough that neighbouring samples are about two pixels apart along the longest path (at least 12, at most 100), so a long blur
    /// is smooth and not a row of ghosts.
    public static func samples(width: Int, height: Int, spin: Bool, amount: Double) -> Int {
        min(max(Int((Double(reach(width: width, height: height, spin: spin, amount: amount)) / 2).rounded(.up)), 12), 100)
    }
    public static let zoomExtent = 0.1, spinExtentDegrees = 10.0

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, spin: Bool, amount: Double, centreX: Double, centreY: Double) -> [SIMD3<Double>] {
        guard amount != 0 else { return rgb }
        let cx = centreX * Double(width - 1), cy = centreY * Double(height - 1)
        let samples = samples(width: width, height: height, spin: spin, amount: amount)
        var out = rgb
        for y in 0..<height {
            for x in 0..<width {
                var sum = SIMD3<Double>(repeating: 0)
                let rx = Double(x) - cx, ry = Double(y) - cy
                for k in -samples...samples {
                    let f = Double(k) / Double(samples)
                    let p: SIMD2<Double>
                    if spin {
                        let a = f * amount * spinExtentDegrees * .pi / 180
                        p = SIMD2(cx + rx * cos(a) - ry * sin(a), cy + rx * sin(a) + ry * cos(a))
                    } else {
                        let s = 1 + f * amount * zoomExtent
                        p = SIMD2(cx + rx * s, cy + ry * s)
                    }
                    for c in 0..<3 { sum[c] += Remap.sample(rgb, width: width, height: height, at: p, channel: c) }
                }
                out[y * width + x] = sum / Double(2 * samples + 1)
            }
        }
        return out
    }

    /// The farthest a sample reads from its pixel (pixels, rounded up, +2): the region a GPU kernel must be given.
    public static func reach(width: Int, height: Int, spin: Bool, amount: Double) -> Int {
        let half = hypot(Double(width), Double(height))
        let extent = spin ? 2 * sin(amount * spinExtentDegrees * .pi / 360) : amount * zoomExtent
        return Int((half * abs(extent)).rounded(.up)) + 2
    }
}
