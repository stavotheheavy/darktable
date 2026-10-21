// Method: removal of colour fringes (purple and green edges a lens leaves around high-contrast detail). A pixel is a fringe candidate where two things hold: it sits on a
// strong luminance edge, e = |Y - blur(Y)| / max(blur(Y), 0.02) through smoothstep(0.05, 0.3), and its colour is in the fringe hue (the colour-range matte of `MaskColour`, OkLab
// hue window about `hue` of half-width `width`, chroma floor 0.02, feather 0.4). The weight m = edge x matte then takes the colour out: the OkLab chroma (a, b) is scaled by
// 1 - strength m, lightness kept. Strength 0 is the identity; flat areas and colours outside the hue window are untouched.

import Foundation

public enum Defringe {
    public static let edgeLow = 0.05, edgeHigh = 0.3, lumaFloor = 0.02, chromaFloor = 0.02, feather = 0.4

    public static func params(hueDegrees: Double, widthDegrees: Double) -> [Double] {
        MaskColour.params(["mask_hue": hueDegrees, "mask_hue_width": widthDegrees, "mask_chroma_min": chromaFloor, "mask_feather": feather])
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Int, strength: Double, hueDegrees: Double, widthDegrees: Double) -> [SIMD3<Double>] {
        guard strength != 0, radius > 0 else { return rgb }
        let y = rgb.map { v -> SIMD3<Double> in let l = ColorCommon.luminance(v); return SIMD3(l, l, l) }
        let yb = Blur.apply(y, width: width, height: height, radius: radius)
        let p = params(hueDegrees: hueDegrees, widthDegrees: widthDegrees)
        return rgb.indices.map { i in
            let edge = ColorCommon.smoothstep(edgeLow, edgeHigh, abs(y[i].x - yb[i].x) / max(yb[i].x, lumaFloor))
            let m = edge * MaskColour.alpha(p: p, rgb: rgb[i])
            var lab = OkLab.fromWorking(rgb[i])
            let k = 1 - strength * m
            lab.y *= k
            lab.z *= k
            return OkLab.toWorking(lab)
        }
    }
}
