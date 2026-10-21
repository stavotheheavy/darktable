// Method: a vignette is a radial filter turned inside out: the surround of a circle darkened by an exposure change through a soft matte
// (`RadialLight`, Porter and Duff, SIGGRAPH 1984, for the mix). The circle is centred on the picture; its radius is `scale` times half the
// picture's diagonal, so at scale 1 the corners sit on the edge of the circle; the matte feathers over the whole radius, so the change
// eases in from the centre (untouched) to the corners (the full change) and stays there beyond the circle.
//
// Settings: strength 0...2, the darkening at the far edge in stops divided by two (so 1 is -2 EV and 2 is -4 EV); 0 is the identity.
// scale 0...2, the circle's radius against half the diagonal.

import Foundation

public enum Vignette {
    /// The exposure change at and beyond the circle, in EV.
    public static func ev(strength: Double) -> Double { -2 * strength }

    /// The circle's half width as a fraction of the picture's diagonal (`RadialLight`'s size, which wants at least 0.02).
    public static func size(scale: Double) -> Double { max(0.02, 0.5 * scale) }

    /// The matte: the picture's centre, a circle, feathered over its whole radius, inverted so the surround is what changes.
    public static func spec(scale: Double) -> MaskSpec {
        RadialLight.spec(x: 0.5, y: 0.5, size: size(scale: scale), shape: 1, rotation: 0, feather: 1, outside: true)
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, strength: Double, scale: Double) -> [SIMD3<Double>] {
        RadialLight.apply(rgb, width: width, height: height, ev: ev(strength: strength), spec: spec(scale: scale))
    }
}
