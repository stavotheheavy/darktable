// Method: a halftone screen (the printing technique that renders tone as ink dots of varying size on a regular grid): the frame is cut into square cells of `size` pixels on a grid
// turned by `angle`, each cell has one round dot at its centre whose area follows the darkness of the picture there (radius = 0.7071 size sqrt(1 - Ye), Ye the display-encoded
// luminance, the sRGB transfer curve of IEC 61966-2-1, of the pixel nearest the cell centre), anti-aliased over one pixel (and faded out below half a pixel of radius, so white stays clean paper). Ink is black on white paper, or the colour of that pixel
// when `colour` is 1 (a colour-separation look). The result is mixed in by `amount` (0 is the identity).

import Foundation

public enum Halftone {
    /// The reach of the pixel read for a pixel: its cell centre is within about 0.71 size of it.
    public static func reach(size: Double) -> Int { Int((0.75 * size).rounded(.up)) + 3 }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, size s: Double, angleDegrees: Double, colour: Bool, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0, s >= 1 else { return rgb }
        let t = angleDegrees * .pi / 180, ct = cos(t), st = sin(t)
        return rgb.indices.map { i in
            let px = Double(i % width) + 0.5, py = Double(i / width) + 0.5
            let u = px * ct + py * st, v = -px * st + py * ct
            let cu = (u / s).rounded(.down) * s + s / 2, cv = (v / s).rounded(.down) * s + s / 2
            let cx = cu * ct - cv * st, cy = cu * st + cv * ct
            let sx = min(max(Int(cx.rounded(.down)), 0), width - 1), sy = min(max(Int(cy.rounded(.down)), 0), height - 1)
            let c = rgb[sy * width + sx]
            let darkness = 1 - Emboss.encodedLuma(c)
            let radius = 0.7071 * s * darkness.squareRoot()
            let dist = hypot(u - cu, v - cv)
            let coverage = (1 - ColorCommon.smoothstep(radius - 0.5, radius + 0.5, dist)) * ColorCommon.smoothstep(0, 0.5, radius)
            let ink = colour ? c : SIMD3<Double>(repeating: 0)
            let out = SIMD3<Double>(repeating: 1) + (ink - SIMD3<Double>(repeating: 1)) * coverage
            return rgb[i] + amount * (out - rgb[i])
        }
    }
}
