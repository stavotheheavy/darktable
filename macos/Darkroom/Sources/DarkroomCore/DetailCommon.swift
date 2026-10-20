// Method: detail modules edit the square root of luminance, s = sqrt(Y), a variance-stabilising domain (Anscombe, "The
// transformation of Poisson, binomial and negative-binomial data", Biometrika 35, 1948: for shot noise the square root
// makes the noise level roughly independent of brightness), then give the change back to the pixel as a gain on all
// three channels, so hue and chroma ratios stay put.
//
// Shared by the S5 detail cards (sharpen, local contrast, contrast equalizer, noise reduction). The GPU twin is
// DarkroomMetal's MetalDetailCommon; darkroom-engine-check E-DC proves they agree.

import Foundation

public enum DetailCommon {
    /// Below this luminance a pixel is left alone: the gain Y'/Y is not defined, and the pixel is black to the eye.
    public static let minLuminance = 1e-6

    /// s = sqrt(max(Y, 0)) for every pixel, Y the Rec.709 luminance of the working-space RGB.
    public static func sqrtLuminance(_ rgb: [SIMD3<Double>], width: Int, height: Int) -> Plane {
        Plane(width: width, height: height, values: rgb.map { sqrt(max(ColorCommon.luminance($0), 0)) })
    }

    /// The gain that moves a pixel of luminance `y` to the square-root luminance `newS`: Y' / Y with Y' = max(newS, 0)^2,
    /// and 1 where `y` is at or under `minLuminance`.
    public static func gain(luminance y: Double, newSqrtLuminance newS: Double) -> Double {
        guard y > minLuminance else { return 1 }
        let s = max(newS, 0)
        return s * s / y
    }

    /// `rgb` with its square-root luminance replaced by `newS`: every channel scaled by `gain`.
    public static func applying(sqrtLuminance newS: Plane, to rgb: [SIMD3<Double>]) -> [SIMD3<Double>] {
        precondition(newS.values.count == rgb.count, "plane and image sizes differ")
        return zip(rgb, newS.values).map { $0 * gain(luminance: ColorCommon.luminance($0), newSqrtLuminance: $1) }
    }

    /// A deterministic textured test image for the detail checks: coloured waves, a hard edge, a fine checker patch
    /// and a bright (past white) corner, so every module has something to act on. Values are linear working-space RGB.
    public static func fixture(width: Int, height: Int) -> [SIMD3<Double>] {
        (0..<(width * height)).map { i in
            let x = Double(i % width), y = Double(i / width)
            var r = 0.30 + 0.18 * sin(x / 3.1) * cos(y / 4.7)
            var g = 0.35 + 0.22 * sin(x / 1.7 + y / 2.3)
            var b = 0.18 + 0.10 * cos(x * y / 37)
            if x >= Double(width) * 0.5 { r += 0.25; g += 0.20; b += 0.15 }                       // a hard vertical edge
            if x < 10, y < 10, Int(x + y) % 2 == 0 { r *= 1.5; g *= 1.5; b *= 1.5 }               // a 1-pixel checker patch
            if x >= Double(width) - 6, y >= Double(height) - 6 { r = 3.2; g = 2.6; b = 1.9 }      // past white
            return SIMD3(max(r, 0.002), max(g, 0.002), max(b, 0.002))
        }
    }
}
