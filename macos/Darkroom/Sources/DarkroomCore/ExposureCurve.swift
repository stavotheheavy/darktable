// Method: a power-law slider response (first principles, no darktable source).

import Foundation

/// The exposure slider's response: track position p in -1...1 to stops, ev = sign(p) * |p|^1.7 * limit. Drags land on 0.01 EV and snap to exactly 0 near it.
public enum ExposureCurve {
    public static let power = 1.7, snapZero = 0.02, step = 0.01

    public static func value(position p: Double, limit: Double) -> Double {
        let p = min(max(p, -1), 1)
        let ev = (p < 0 ? -1.0 : 1.0) * pow(abs(p), power) * limit
        if abs(ev) < snapZero { return 0 }
        return (ev / step).rounded() * step
    }

    public static func position(value ev: Double, limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        let r = min(max(ev / limit, -1), 1)
        return (r < 0 ? -1.0 : 1.0) * pow(abs(r), 1 / power)
    }
}
