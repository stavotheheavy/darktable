// Method: the Kuwahara filter (M. Kuwahara, K. Hachimura, S. Eiho and M. Kinoshita, "Processing of RI-angiocardiographic images", 1976), the painterly edge-preserving
// smoother: round each pixel four overlapping (r + 1) by (r + 1) windows meet at it (up-left, up-right, down-left, down-right, edges clamped); the pixel becomes the mean colour
// of the window whose luminance varies least (the smoothest side, which is the side that does not cross an edge). The result is mixed in by `amount` (0 is the identity).
// Radius 0 is the identity.

import Foundation

public enum Kuwahara {
    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius r: Int, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0, r > 0 else { return rgb }
        let luma = rgb.map { ColorCommon.luminance($0) }
        var out = rgb
        for y in 0..<height {
            for x in 0..<width {
                var bestVar = Double.infinity, bestMean = rgb[y * width + x]
                for (sx, sy) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] {
                    var sum = SIMD3<Double>(repeating: 0), ls = 0.0, lq = 0.0
                    for j in 0...r {
                        for i in 0...r {
                            let px = min(max(x + sx * i, 0), width - 1), py = min(max(y + sy * j, 0), height - 1)
                            sum += rgb[py * width + px]
                            ls += luma[py * width + px]; lq += luma[py * width + px] * luma[py * width + px]
                        }
                    }
                    let n = Double((r + 1) * (r + 1))
                    let variance = lq / n - (ls / n) * (ls / n)
                    if variance < bestVar { bestVar = variance; bestMean = sum / n }
                }
                out[y * width + x] = rgb[y * width + x] + amount * (bestMean - rgb[y * width + x])
            }
        }
        return out
    }
}
