import SwiftUI
#if !os(macOS)
import UIKit

/// Captures a brush stroke with the pressure UIKit reports. SwiftUI's drag gesture carries only a position, so a Pencil's
/// pressure is read here: `force` over `maximumPossibleForce` for a pencil, and full pressure for a finger (which has none).
/// It uses the coalesced touches, so a fast stroke keeps every sample the Pencil reported, not just one per frame.
struct StrokeCapture: UIViewRepresentable {
    var onBegan: (CGPoint, Double) -> Void
    var onMoved: (CGPoint, Double) -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = false
        return v
    }

    func updateUIView(_ v: CaptureView, context: Context) {
        v.onBegan = onBegan
        v.onMoved = onMoved
        v.onEnded = onEnded
    }

    final class CaptureView: UIView {
        var onBegan: ((CGPoint, Double) -> Void)?
        var onMoved: ((CGPoint, Double) -> Void)?
        var onEnded: (() -> Void)?

        /// 0...1: how hard a pencil pressed. A finger, or a device that reports no force, counts as full pressure.
        static func pressure(_ t: UITouch) -> Double {
            guard t.type == .pencil, t.maximumPossibleForce > 0 else { return 1 }
            return min(max(Double(t.force / t.maximumPossibleForce), 0), 1)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first else { return }
            onBegan?(t.location(in: self), Self.pressure(t))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first else { return }
            for sample in event?.coalescedTouches(for: t) ?? [t] {
                onMoved?(sample.location(in: self), Self.pressure(sample))
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { onEnded?() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { onEnded?() }
    }
}
#endif
