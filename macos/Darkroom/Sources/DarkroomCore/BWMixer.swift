// Method: the black-and-white channel mixer of darkroom and digital practice (the red, orange and yellow filters on a lens are weights on the colour channels): the grey is the weighted
// sum of the scene-linear channels, Y = wr R + wg G + wb B, each weight from -1 to 2 (the working space's luminance weights give an honest luminance; a high red weight
// darkens skies and lightens skin as a red filter does). All three channels become Y, mixed in by `amount` (0 is the identity).

import Foundation

public enum BWMixer {
    public static func apply(_ rgb: SIMD3<Double>, weights: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        let y = weights.x * rgb.x + weights.y * rgb.y + weights.z * rgb.z
        return rgb + amount * (SIMD3(repeating: y) - rgb)
    }
}
