// Method: OkLab (Björn Ottosson, "A perceptual color space for image processing", 2020); a hue and chroma offset per tone range, weighted by a smoothstep around a balance pivot, as the splittoning card gives it
import Foundation

/// Split toning: a shadows tint and a highlights tint, each a chroma offset in OkLab at its own hue, split by
/// lightness at a pivot that `balance` moves. Lightness never changes. Zero saturations are the identity.
public enum SplitToning {
    public static func apply(_ rgb: SIMD3<Double>, shadowsHueDegrees: Double, shadowsSaturation: Double,
                             highlightsHueDegrees: Double, highlightsSaturation: Double, balance: Double) -> SIMD3<Double> {
        let lab = OkLab.fromWorking(rgb)
        let pivot = 0.5 + 0.25 * balance
        let wh = ColorCommon.smoothstep(pivot - 0.2, pivot + 0.2, lab.x)
        let ws = 1 - wh
        let sh = shadowsHueDegrees * .pi / 180, hh = highlightsHueDegrees * .pi / 180
        let a = lab.y + 0.08 * (shadowsSaturation * ws * cos(sh) + highlightsSaturation * wh * cos(hh))
        let b = lab.z + 0.08 * (shadowsSaturation * ws * sin(sh) + highlightsSaturation * wh * sin(hh))
        return OkLab.toWorking(SIMD3(lab.x, a, b))
    }
}
