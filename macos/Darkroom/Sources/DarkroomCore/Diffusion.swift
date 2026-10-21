// Method: anisotropic diffusion (P. Perona and J. Malik, "Scale-space and edge detection using anisotropic diffusion", IEEE PAMI 12, 1990): n iterations of
// u += lambda sum over the four neighbours of g(|d|) d, with d the difference to the neighbour and the conductance g(|d|) = 1 / (1 + (|d| / K)^2), so flat noise is
// averaged away while a step much larger than K is almost not crossed. lambda is 0.2 (stable below 0.25). It runs per channel on the square root of the scene value
// (the variance-stabilising domain of `DetailCommon`), clamped at the frame edges. Zero iterations is the identity.

import Foundation

public enum Diffusion {
    public static let lambda = 0.2

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, iterations: Int, threshold k: Double) -> [SIMD3<Double>] {
        guard iterations > 0 else { return rgb }
        var u = rgb.map { SIMD3(sqrt(max($0.x, 0)), sqrt(max($0.y, 0)), sqrt(max($0.z, 0))) }
        for _ in 0..<iterations {
            var next = u
            for y in 0..<height {
                for x in 0..<width {
                    let c = u[y * width + x]
                    var flow = SIMD3<Double>(repeating: 0)
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let n = u[min(max(y + dy, 0), height - 1) * width + min(max(x + dx, 0), width - 1)]
                        let d = n - c
                        flow += d / (1 + (d * d) / (k * k))
                    }
                    next[y * width + x] = c + lambda * flow
                }
            }
            u = next
        }
        return u.map { SIMD3($0.x * $0.x, $0.y * $0.y, $0.z * $0.z) }
    }
}
