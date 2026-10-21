// Method: a gradient map in OkLab (Björn Ottosson, 2020): the picture's own lightness picks a colour from a three-stop gradient (shadows at L = 0,
// midtones at L = 0.5, highlights at L >= 1), blended between stops with a smoothstep, and the pixel's chroma vector (a, b) is mixed toward that colour
// by `strength`. Lightness never changes, so strength 1 is a duotone or tritone print with the picture's own tones; strength 0 is the identity.

import Foundation

public enum GradientMap {
    /// OkLab chroma of a stop at saturation 1.
    public static let chroma = 0.12

    /// A stop's (a, b) for a hue in degrees and a saturation 0...1.
    public static func stop(hueDegrees: Double, saturation: Double) -> SIMD2<Double> {
        let h = hueDegrees * .pi / 180
        return SIMD2(chroma * saturation * cos(h), chroma * saturation * sin(h))
    }

    /// `stops` = shadows, midtones, highlights as (a, b).
    public static func apply(_ rgb: SIMD3<Double>, strength: Double, stops: [SIMD2<Double>]) -> SIMD3<Double> {
        var lab = OkLab.fromWorking(rgb)
        let l = min(max(lab.x.isNaN ? 0 : lab.x, 0), 1)
        let target = l < 0.5
            ? stops[0] + (stops[1] - stops[0]) * ColorCommon.smoothstep(0, 0.5, l)
            : stops[1] + (stops[2] - stops[1]) * ColorCommon.smoothstep(0.5, 1, l)
        lab.y += (target.x - lab.y) * strength
        lab.z += (target.y - lab.z) * strength
        return OkLab.toWorking(lab)
    }
}
