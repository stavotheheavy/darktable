// Sharpen as a CPU reference (checkpoint B3). Each pixel gets its own value plus `amount` times the
// difference from the average of itself and its two neighbours. The line is clamped at both ends.
//
// This works along a 1-D line of pixels, as the chain does for now. A real sharpen works on a 2-D
// neighbourhood; that comes with the spatial stages in M4.

import Foundation

public enum Sharpen {
    public static func line(_ px: [SIMD3<Double>], amount: Double) -> [SIMD3<Double>] {
        px.indices.map { i in
            let prev = px[max(i - 1, 0)], next = px[min(i + 1, px.count - 1)]
            let blur = (prev + px[i] + next) / 3
            return px[i] + amount * (px[i] - blur)
        }
    }
}
