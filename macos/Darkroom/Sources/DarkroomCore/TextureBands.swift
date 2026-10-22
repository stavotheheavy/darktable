// Method: mid-frequency contrast (texture, or clarity at a larger radius) as a band-pass in the square-root luminance domain of `DetailCommon` (Anscombe 1948, the
// variance-stabilising domain the other detail modules use, which keeps the gain bounded in the shadows): s = sqrt(Y), the band is the difference of two blurs of s,
// the finer at the chosen radius and the coarser that same fine blur blurred again at three times the radius (a band-pass: smooth at r, then high-pass at 3r; the
// cascade keeps the two images distinct on the GPU), b1 = blur_r(s), s' = s + amount (b1 - blur_3r(b1)), and the change is given back to the pixel as a gain on all three channels (DetailCommon.applying), so hue and chroma ratios stay put. Amount 0 is the
// identity and a negative amount smooths that band.

import Foundation

public enum TextureBands {
    public static func blurred(_ p: Plane, radius: Double) -> Plane {
        var out = p
        for _ in 0..<Blur.passes { out = Filters.boxMean(out, radius: radius) }
        return out
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radiusPixels: Double, amount: Double) -> [SIMD3<Double>] {
        let r1 = Blur.radius(px: radiusPixels), r3 = Blur.radius(px: 3 * radiusPixels)
        guard amount != 0, r1 > 0 else { return rgb }
        let s = DetailCommon.sqrtLuminance(rgb, width: width, height: height)
        let b1 = blurred(s, radius: r1), b3 = blurred(b1, radius: r3)
        let sNew = Plane(width: width, height: height, values: s.values.indices.map { s.values[$0] + amount * (b1.values[$0] - b3.values[$0]) })
        return DetailCommon.applying(sqrtLuminance: sNew, to: rgb)
    }
}
