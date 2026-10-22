// Method: a low-pass of the tone with the colour kept: the square root of luminance (s = sqrt(Y), the variance-stabilising domain of `DetailCommon`, Anscombe 1948) is blurred with
// `Blur`'s three box means and given back to the pixel as a gain (DetailCommon.applying), so the fine detail of the light is smoothed while hue and chroma ratios stay put and
// fine colour detail survives. That is what separates it from `blurs`, which blurs every channel. Radius 0 is the identity.

import Foundation

public enum LowPass {
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Double) -> [SIMD3<Double>] {
        guard radius > 0 else { return rgb }
        let s = DetailCommon.sqrtLuminance(rgb, width: width, height: height)
        return DetailCommon.applying(sqrtLuminance: TextureBands.blurred(s, radius: radius), to: rgb)
    }
}
