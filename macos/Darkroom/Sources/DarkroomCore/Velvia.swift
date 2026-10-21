// Method: the vibrance step of `ColorBalance` on its own: OkLab chroma (Björn Ottosson, 2020) is multiplied by 1 + strength * w, where w is
// 1 for a grey and falls smoothly to 0 at chroma 0.2. Pale colours gain the most, strongly saturated ones are left alone, lightness and
// hue are kept, and a grey stays grey.
//
// This is what the module's name asks for (a film-like boost that does not push the colours that are already vivid into clipping),
// and it runs on the colour balance kernel, so it has no kernel of its own.

import Foundation

public enum Velvia {
    /// Linear working-space RGB in, the same kind out. `strength` 0 is the identity, 1 doubles the chroma of a grey-ish colour.
    public static func apply(_ rgb: SIMD3<Double>, strength: Double) -> SIMD3<Double> {
        ColorBalance.apply(rgb, contrast: 0, saturation: 0, vibrance: strength)
    }
}
