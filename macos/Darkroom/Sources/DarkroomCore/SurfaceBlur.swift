// Method: an edge-preserving blur, the guided filter (K. He, J. Sun, X. Tang, "Guided Image Filtering", ECCV 2010) with the picture's own luminance as the guide: flat and
// finely textured areas are averaged while edges whose luminance step is larger than the threshold `eps` keep their sharpness. The filter runs on the square root of the channels (a
// perceptual domain: the same contrast is an edge at every tone; on scene-linear values the absolute eps called dark detail flat and smeared it while bright edges stayed). The result is mixed in by `amount` (0 is
// the identity). Where `skin smoothing` masks this smooth by a colour, the surface blur is the whole picture.

import Foundation

public enum SurfaceBlur {
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Double, eps: Double, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0, radius > 0 else { return rgb }
        let enc = rgb.map { SIMD3(max($0.x, 0).squareRoot(), max($0.y, 0).squareRoot(), max($0.z, 0).squareRoot()) }.map { SIMD3($0.x.isFinite ? $0.x : 0, $0.y.isFinite ? $0.y : 0, $0.z.isFinite ? $0.z : 0) }
        let guide = Plane(width: width, height: height, values: enc.map { ColorCommon.luminance($0) })
        let smooth = (0..<3).map { c in Filters.guided(guide: guide, input: Plane(width: width, height: height, values: enc.map { $0[c] }), radius: radius, eps: eps) }
        return rgb.indices.map { i in
            let e = SIMD3(max(smooth[0].values[i], 0), max(smooth[1].values[i], 0), max(smooth[2].values[i], 0))
            return rgb[i] + amount * (e * e - rgb[i])
        }
    }
}
