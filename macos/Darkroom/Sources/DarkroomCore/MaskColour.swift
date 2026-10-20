// Method: colour range mask in OkLab (Ottosson, "A perceptual color space for image processing", 2020): the weight is
// a hue window around a chosen hue (wrapped at 360 degrees) times a chroma floor that excludes greys; lightness is ignored.

import Foundation

public enum MaskColour {
    /// [hue (rad), half-width (rad), chroma floor, feather] from `mask_hue`, `mask_hue_width` (deg), `mask_chroma_min`, `mask_feather`.
    public static func params(_ blend: [String: Double]) -> [Double] {
        let hue = (blend["mask_hue"] ?? 30) * .pi / 180
        let width = min(max(blend["mask_hue_width"] ?? 30, 1), 180) * .pi / 180
        let chroma = min(max(blend["mask_chroma_min"] ?? 0.02, 0), 0.5)
        let feather = min(max(blend["mask_feather"] ?? 0.3, 0), 1)
        return [hue, width, chroma, feather]
    }

    public static func alpha(p: [Double], rgb: SIMD3<Double>) -> Double {
        let lch = OkLab.lch(OkLab.fromWorking(rgb))
        let dh = abs(ColorCommon.hueDifference(lch.z, p[0]))
        let chroma = lch.y
        guard dh.isFinite, chroma.isFinite else { return 0 }
        let hueW = 1 - Mask.ramp(p[1] * (1 - p[3]), p[1], dh)
        let chromaW = p[2] <= 0 ? 1 : Mask.ramp(p[2] * (1 - p[3]), p[2], chroma)
        return hueW * chromaW
    }
}
