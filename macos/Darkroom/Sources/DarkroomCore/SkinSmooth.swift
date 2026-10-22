// Method: skin retouching as a masked edge-aware smooth: the picture is smoothed with a guided filter (K. He, J. Sun, X. Tang, ECCV 2010) guided by its own luminance
// (so pores and fine texture soften while eyes, lips and hair edges stay), run on the square root of the channels (a perceptual domain: the same contrast is an edge at every tone;
// on scene-linear values the absolute eps treated dark hair as flat and averaged it into clumps), and the smoothed picture is mixed in only where the colour is skin-like, by the
// colour-range matte of `MaskColour` (OkLab hue window around the skin hue, with a chroma floor and a feather of 0.4). out = rgb + amount * matte * (smooth - rgb).
// `amount` 0 is the identity.

import Foundation

public enum SkinSmooth {
    public static let eps = 0.001, chromaFloor = 0.03, feather = 0.4

    public static func params(hueDegrees: Double, widthDegrees: Double) -> [Double] {
        MaskColour.params(["mask_hue": hueDegrees, "mask_hue_width": widthDegrees, "mask_chroma_min": chromaFloor, "mask_feather": feather])
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Int, amount: Double, hueDegrees: Double, widthDegrees: Double) -> [SIMD3<Double>] {
        guard amount != 0, radius > 0 else { return rgb }
        let enc = rgb.map { SIMD3($0.x.squareRoot(), $0.y.squareRoot(), $0.z.squareRoot()) }.map { SIMD3($0.x.isFinite ? $0.x : 0, $0.y.isFinite ? $0.y : 0, $0.z.isFinite ? $0.z : 0) }
        let guide = Plane(width: width, height: height, values: enc.map { ColorCommon.luminance($0) })
        let smooth = (0..<3).map { c in Filters.guided(guide: guide, input: Plane(width: width, height: height, values: enc.map { $0[c] }), radius: radius, eps: eps) }
        let p = params(hueDegrees: hueDegrees, widthDegrees: widthDegrees)
        return rgb.indices.map { i in
            let e = SIMD3(max(smooth[0].values[i], 0), max(smooth[1].values[i], 0), max(smooth[2].values[i], 0))
            let s = e * e
            return rgb[i] + amount * MaskColour.alpha(p: p, rgb: rgb[i]) * (s - rgb[i])
        }
    }
}
