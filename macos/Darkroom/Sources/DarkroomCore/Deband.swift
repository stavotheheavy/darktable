// Method: debanding: in smooth gradients, where 8-bit or compressed data steps in visible bands, the picture is replaced by its own blur (`Blur`); at real edges and
// texture it is left alone. The weight is w = strength * (1 - smoothstep(0, threshold, d)) with d the largest channel difference between the picture and its blur on
// the display-encoded value (sRGB transfer curve, IEC 61966-2-1), so a pixel that already agrees with its surroundings (the band step is small) is smoothed and a pixel
// that differs a lot (an edge) is not. out = rgb + w (blur - rgb). Strength 0 is the identity.

import Foundation

public enum Deband {
    static func enc(_ v: Double) -> Double { v.isNaN ? 0 : Transfer.linearToSRGB(min(max(v, 0), 1)) }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Int, threshold: Double, strength: Double) -> [SIMD3<Double>] {
        guard strength != 0, radius > 0 else { return rgb }
        let blurred = Blur.apply(rgb, width: width, height: height, radius: radius)
        return rgb.indices.map { i in
            let p = rgb[i], b = blurred[i]
            let d = max(abs(enc(p.x) - enc(b.x)), abs(enc(p.y) - enc(b.y)), abs(enc(p.z) - enc(b.z)))
            let wgt = strength * (1 - ColorCommon.smoothstep(0, threshold, d))
            return p + wgt * (b - p)
        }
    }
}
