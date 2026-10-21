// Method: OkLab LCh (Björn Ottosson, "A perceptual color space for image processing", 2020); eight hue bands whose settings are blended by a smoothstep between the two nearest band centres (a piecewise curve over hue, wrapped at 360 degrees), applied with a chroma floor so greys are left alone.

import Foundation

/// Colour zones: for each of eight hue bands a hue shift, a saturation change and a lightness change, all in OkLab. A pixel takes the
/// blend of its two neighbouring bands' settings, so a slider moves a smooth range of hues and never a hard edge. Zero settings are the identity.
public enum ColorZones {
    public static let bandNames = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
    /// Band centres in OkLab hue degrees, ascending.
    public static let centresDegrees: [Double] = [29, 55, 110, 142, 195, 264, 305, 350]
    /// A hue slider of 1 turns the band by this many degrees; a lightness slider of 1 moves OkLab L by `lightnessRange`.
    public static let hueRangeDegrees = 30.0
    public static let lightnessRange = 0.25
    /// Chroma below which a colour is a grey and is not touched; the effect is full above `chromaFull`.
    public static let chromaFloor = 0.0, chromaFull = 0.04

    /// `u` is hue (8), saturation (8), lightness (8): the sliders, each -1...1.
    public static func apply(_ rgb: SIMD3<Double>, u: [Double]) -> SIMD3<Double> {
        let lab = OkLab.fromWorking(rgb)
        let chroma = hypot(lab.y, lab.z)
        let w = ColorCommon.smoothstep(chromaFloor, chromaFull, chroma)
        guard w > 0, chroma.isFinite else { return rgb }
        let tau = 2 * Double.pi
        var h = atan2(lab.z, lab.y)
        if h < 0 { h += tau }
        let c = centresDegrees.map { $0 * .pi / 180 }
        // the segment [c[i], c[i+1]] the hue falls in; below the first centre it is the wrap segment from the last
        var i = 7
        if h >= c[0] { for k in 0..<7 where h >= c[k] && h < c[k + 1] { i = k } } else { h += tau }
        let j = (i + 1) % 8
        let cj = c[j] + (j == 0 ? tau : 0)
        let t = ColorCommon.smoothstep(0, 1, (h - c[i]) / (cj - c[i]))
        func mix(_ base: Int) -> Double { u[base + i] * (1 - t) + u[base + j] * t }
        let dh = mix(0) * hueRangeDegrees * .pi / 180 * w
        let k = max(1 + mix(8) * w, 0)
        let dl = mix(16) * lightnessRange * w
        let hue = h + dh
        let c2 = chroma * k
        return OkLab.toWorking(SIMD3(max(lab.x + dl, 0), c2 * cos(hue), c2 * sin(hue)))
    }
}
