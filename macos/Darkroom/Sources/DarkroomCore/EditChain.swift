// The first edit chain: exposure, white balance and tint, tone, sharpen, then the display transform.
// Pixels are scene-linear Rec.2020 on the way in and display-referred sRGB (0...1, encoded) out.
//
// The order is the plan's (P4): spatial stages come after the scene-linear gain, so an exposure
// change is a gain and the sharpen result can be reused. Tone is applied per channel for now; a
// luminance-based tone map that keeps hue is M3 work.

import Foundation

/// Scene-linear Rec.2020 to display sRGB: the matrix, then the sRGB curve, clipped to 0...1.
/// The own transform the plan calls for (no AgX). Only SDR is covered so far.
public enum DisplayTransform {
    public static func apply(_ scene: SIMD3<Double>) -> SIMD3<Double> {
        let s = ColorSpaces.rec2020ToSRGB.apply(scene)
        return SIMD3(encode(s.x), encode(s.y), encode(s.z))
    }

    static func encode(_ linear: Double) -> Double {
        min(max(Transfer.linearToSRGB(max(linear, 0)), 0), 1)
    }
}

public enum EditChain {
    /// The stages for one set of slider values. Stage names are the cache and test keys.
    public static func stages(ev: Double, kelvin: Double, tint: Double, contrast: Double, sharpen: Double) -> [Stage] {
        let tone = ToneMap(contrast: contrast)
        let wb = WhiteBalance.gains(kelvin: kelvin, tint: tint)
        return [
            Stage(name: "exposure", params: "\(ev)") { px in
                px.map { $0 * Exposure.gain(ev: ev) }
            },
            Stage(name: "whitebalance", params: "\(kelvin),\(tint)") { px in
                px.map { $0 * wb }
            },
            Stage(name: "tone", params: "\(contrast)") { px in
                px.map { SIMD3(tone.apply($0.x), tone.apply($0.y), tone.apply($0.z)) }
            },
            Stage(name: "sharpen", params: "\(sharpen)") { px in
                px.indices.map { i in
                    let prev = px[max(i - 1, 0)], next = px[min(i + 1, px.count - 1)]
                    let blur = (prev + px[i] + next) / 3
                    return px[i] + sharpen * (px[i] - blur)
                }
            },
            Stage(name: "display", params: "srgb") { px in
                px.map(DisplayTransform.apply)
            },
        ]
    }
}
