// Method: a radial filter: an exposure change through a soft elliptical matte (Mask kind 2, MaskEllipse), the way a
// photographer paints light with a spotlight or a vignette in reverse. The change is a gain on linear light (2^EV), mixed
// by the matte over the unchanged picture (Porter and Duff, SIGGRAPH 1984). With `outside` the matte is inverted: the
// light is changed everywhere except inside the ellipse, which darkens the surround for a spotlight look.
//
// Settings: exposure in EV (0 is the identity); x and y the centre as fractions of the upright picture; size the half
// width as a fraction of the picture's diagonal; shape the height over the width (1 is a circle); rotation in degrees;
// feather the soft band (0 hard, 1 the whole radius); outside 0 or 1.

import Foundation

public enum RadialLight {
    /// The ellipse matte for these settings, in the upright picture (the engine adds the camera's orientation).
    public static func spec(x: Double, y: Double, size: Double, shape: Double, rotation: Double, feather: Double,
                            outside: Bool) -> MaskSpec {
        let blend: [String: Double] = [
            "mask_mode": 2, "mask_kind": 2, "mask_cx": x, "mask_cy": y, "mask_rx": size, "mask_ry": size * shape,
            "mask_rotation": rotation, "mask_feather": feather, "mask_invert": outside ? 1 : 0,
        ]
        return Mask.spec(from: blend)!
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, ev: Double, spec: MaskSpec) -> [SIMD3<Double>] {
        guard ev != 0 else { return rgb }
        let g = Exposure.gain(ev: ev)
        return Mask.apply(spec, to: rgb, width: width, height: height) { $0.map { $0 * g } }
    }
}
