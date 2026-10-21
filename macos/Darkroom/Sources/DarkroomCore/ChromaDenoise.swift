// Method: chroma noise reduction in OkLab (Björn Ottosson, 2020): the a and b planes are smoothed with a guided filter (K. He, J. Sun, X. Tang, "Guided Image
// Filtering", ECCV 2010) whose guide is the picture's own luminance, so colour noise is averaged away without colour bleeding across edges of the picture; the
// lightness plane is not touched, so detail and sharpness stay. The result is mixed in by `amount` (0 is the identity). `radius` is the box radius in pixels.

import Foundation

public enum ChromaDenoise {
    /// The guided filter's edge threshold, on scene-linear luminance.
    public static let eps = 0.002

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Int, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0, radius > 0 else { return rgb }
        let lab = rgb.map { OkLab.fromWorking($0) }
        let guide = Plane(width: width, height: height, values: rgb.map { ColorCommon.luminance($0) })
        let a = Filters.guided(guide: guide, input: Plane(width: width, height: height, values: lab.map { $0.y }), radius: radius, eps: eps)
        let b = Filters.guided(guide: guide, input: Plane(width: width, height: height, values: lab.map { $0.z }), radius: radius, eps: eps)
        return rgb.indices.map { i in
            OkLab.toWorking(SIMD3(lab[i].x, lab[i].y + amount * (a.values[i] - lab[i].y), lab[i].z + amount * (b.values[i] - lab[i].z)))
        }
    }
}
