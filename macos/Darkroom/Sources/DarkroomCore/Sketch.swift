// Method: a pencil sketch: the Sobel gradient magnitude of the display-encoded luminance (I. Sobel and G. Feldman, 1968; the sRGB transfer curve of IEC 61966-2-1), drawn as dark
// lines on white paper: line = 1 - clamp(strength x magnitude, 0, 1), a grey picture mixed in by `amount` (0 is the identity). Reads are clamped at the frame edge.

import Foundation

public enum Sketch {
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, strength: Double, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0 else { return rgb }
        let ye = rgb.map { Emboss.encodedLuma($0) }
        func at(_ x: Int, _ y: Int) -> Double { ye[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)] }
        return rgb.indices.map { i in
            let x = i % width, y = i / width
            let gx = (at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2 * at(x - 1, y) + at(x - 1, y + 1))
            let gy = (at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2 * at(x, y - 1) + at(x + 1, y - 1))
            let line = 1 - min(max(strength * hypot(gx, gy), 0), 1)
            return rgb[i] + amount * (SIMD3(repeating: Transfer.srgbToLinear(line)) - rgb[i])
        }
    }
}
