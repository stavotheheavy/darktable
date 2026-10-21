// Method: the ASC CDL transfer function (American Society of Cinematographers Color Decision List: out = (in * slope + offset) ^ power, per channel), with the power taken about scene white (1.0), so black and white stay put and a positive brightness lifts everything between; each range's tint is a chroma direction in OkLab (Björn Ottosson, 2020) turned into per-channel factors.

import Foundation

/// Four-way colour balance: shadows (the CDL offset), midtones (its power) and highlights (its slope), each with a tint (hue and strength)
/// and a brightness. On scene-linear values. All tints at zero strength and all brightnesses at zero are the identity.
public enum LiftGammaGain {
    /// Scene white, the pivot of the power: x^p keeps 0 and 1 fixed, which is what a midtone (gamma) control should do.
    public static let pivot = 1.0
    /// OkLab chroma of a full-strength tint, and the scene-linear size of a full brightness slider on each range:
    /// highlights one stop of slope, midtones a power of 2^(-1/2) (`midRange`), shadows `offsetRange` of linear light.
    public static let tintChroma = 0.1
    public static let offsetRange = 0.04
    public static let midRange = 0.5

    /// Per-channel gain of a tint at `hueDegrees` and `strength` (0...1): grey with the tint's OkLab chroma, over the same grey.
    public static func tint(hueDegrees: Double, strength: Double) -> SIMD3<Double> {
        let h = hueDegrees * .pi / 180
        let grey = OkLab.toWorking(SIMD3(0.7, 0, 0))
        let coloured = OkLab.toWorking(SIMD3(0.7, tintChroma * cos(h), tintChroma * sin(h)))
        let direction = coloured / grey - SIMD3(repeating: 1)
        return SIMD3(repeating: 1) + direction * strength
    }

    /// The terms from the nine sliders: hue (degrees), strength (0...1) and brightness (-1...1) for shadows, midtones and highlights.
    public static func terms(_ v: [String: Double]) -> (slope: SIMD3<Double>, offset: SIMD3<Double>, power: SIMD3<Double>) {
        func range(_ name: String) -> (tint: SIMD3<Double>, lum: Double) {
            (tint(hueDegrees: v["\(name)_hue"] ?? 0, strength: v["\(name)_sat"] ?? 0), v["\(name)_lum"] ?? 0)
        }
        let s = range("shadows"), m = range("mids"), h = range("highlights")
        let slope = h.tint * pow(2, h.lum)
        let offset = ((s.tint - SIMD3(repeating: 1)) + SIMD3(repeating: s.lum)) * offsetRange
        let power = SIMD3(repeating: pow(2, -m.lum * midRange)) / m.tint
        return (slope, offset, power)
    }

    public static func apply(_ rgb: SIMD3<Double>, slope: SIMD3<Double>, offset: SIMD3<Double>, power: SIMD3<Double>) -> SIMD3<Double> {
        var out = SIMD3<Double>(repeating: 0)
        for k in 0..<3 {
            let x = max(rgb[k] * slope[k] + offset[k], 0)
            out[k] = pivot * pow(x / pivot, power[k])
        }
        return out
    }
}
