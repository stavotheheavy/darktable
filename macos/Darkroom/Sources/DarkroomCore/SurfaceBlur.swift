// Method: an edge-preserving blur, the guided filter (K. He, J. Sun, X. Tang, "Guided Image Filtering", ECCV 2010) with the picture's own luminance as the guide: flat and
// finely textured areas are averaged while edges whose luminance step is larger than the threshold `eps` keep their sharpness. The result is mixed in by `amount` (0 is
// the identity). Where `skin smoothing` masks this smooth by a colour, the surface blur is the whole picture.

import Foundation

public enum SurfaceBlur {
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Double, eps: Double, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0, radius > 0 else { return rgb }
        let guide = Plane(width: width, height: height, values: rgb.map { ColorCommon.luminance($0) })
        let smooth = (0..<3).map { c in Filters.guided(guide: guide, input: Plane(width: width, height: height, values: rgb.map { $0[c] }), radius: radius, eps: eps) }
        return rgb.indices.map { i in rgb[i] + amount * (SIMD3(smooth[0].values[i], smooth[1].values[i], smooth[2].values[i]) - rgb[i]) }
    }
}
