// Method: skin retouching as a masked edge-aware smooth: the picture is smoothed with a guided filter (K. He, J. Sun, X. Tang, ECCV 2010) guided by its own luminance
// (so pores and fine texture soften while eyes, lips and hair edges stay), and the smoothed picture is mixed in only where the colour is skin-like, by the
// colour-range matte of `MaskColour` (OkLab hue window around the skin hue, with a chroma floor and a feather of 0.4). out = rgb + amount * matte * (smooth - rgb).
// `amount` 0 is the identity.

import Foundation

public enum SkinSmooth {
    public static let eps = 0.002, chromaFloor = 0.03, feather = 0.4

    public static func params(hueDegrees: Double, widthDegrees: Double) -> [Double] {
        MaskColour.params(["mask_hue": hueDegrees, "mask_hue_width": widthDegrees, "mask_chroma_min": chromaFloor, "mask_feather": feather])
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Int, amount: Double, hueDegrees: Double, widthDegrees: Double) -> [SIMD3<Double>] {
        guard amount != 0, radius > 0 else { return rgb }
        let guide = Plane(width: width, height: height, values: rgb.map { ColorCommon.luminance($0) })
        let smooth = (0..<3).map { c in Filters.guided(guide: guide, input: Plane(width: width, height: height, values: rgb.map { $0[c] }), radius: radius, eps: eps) }
        let p = params(hueDegrees: hueDegrees, widthDegrees: widthDegrees)
        return rgb.indices.map { i in
            let s = SIMD3(smooth[0].values[i], smooth[1].values[i], smooth[2].values[i])
            return rgb[i] + amount * MaskColour.alpha(p: p, rgb: rgb[i]) * (s - rgb[i])
        }
    }
}
