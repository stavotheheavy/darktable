// Method: a soft-focus mix: the picture blended toward its own blur (`Blur`), out = rgb + strength * (blur - rgb). Strength 0 is the
// identity and strength 1 is the blur itself; light is conserved away from the border because the blur conserves it.

import Foundation

public enum Soften {
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, strength: Double, radius: Double) -> [SIMD3<Double>] {
        guard strength != 0, radius > 0 else { return rgb }
        let blurred = Blur.apply(rgb, width: width, height: height, radius: radius)
        return rgb.indices.map { rgb[$0] + strength * (blurred[$0] - rgb[$0]) }
    }
}
