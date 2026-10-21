// Method: a graduated filter: an exposure change through a soft linear gradient (Mask kind 1, MaskGradient), the way a photographer holds
// a graduated neutral-density filter over a bright sky. The change is a gain on linear light (2^EV), mixed by the matte over the unchanged
// picture (Porter and Duff, SIGGRAPH 1984). The matte is 0 on the near side of the line and 1 on the far side, with a smooth band between.
//
// Settings: exposure in EV (0 is the identity); position the line's place along the direction as a fraction of the frame diagonal from the
// start (0.5 is the middle); angle the direction the filter lands toward, in degrees on the upright picture (0 right, 90 down, -90 up);
// feather the width of the band (0 a hard edge, 1 the whole diagonal).

import Foundation

public enum GraduatedFilter {
    /// The gradient matte for these settings, in the upright picture (the engine adds the camera's orientation).
    public static func spec(position: Double, angle: Double, feather: Double) -> MaskSpec {
        let blend: [String: Double] = [
            "mask_mode": 2, "mask_kind": 1, "mask_angle": angle, "mask_position": position, "mask_feather": feather,
        ]
        return Mask.spec(from: blend)!
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, ev: Double, spec: MaskSpec) -> [SIMD3<Double>] {
        guard ev != 0 else { return rgb }
        let g = Exposure.gain(ev: ev)
        return Mask.apply(spec, to: rgb, width: width, height: height) { $0.map { $0 * g } }
    }
}
