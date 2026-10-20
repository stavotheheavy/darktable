// Method: a local mask is a per-pixel weight alpha in 0...1 from the pixel's position or colour; the module's output is
// mixed over its input by `opacity * alpha` (the compositing "over" rule with a matte, Porter and Duff, "Compositing
// Digital Images", SIGGRAPH 1984). A mask can be refined to the photo's edges with the guided filter (He, Sun and Tang,
// ECCV 2010) guided by the photo's own square-root luminance.
//
// Masks live in a stack entry's `blend` dictionary (numbers only, so history, undo and the sidecar already carry them):
//   mask_mode 2 = local mask; mask_kind 0 whole frame (alpha 1; the plumbing checks use it), 1 gradient, 2 ellipse, 3 luminance range, 4 colour range;
//   mask_invert 0/1; mask_refine = guided-filter radius in pixels (0 = off); opacity 0...100 as for every blend.
// Each kind reads its own keys (MaskGradient ... MaskColour). Coordinates are pixels of the frame the stack runs on
// (the sensor-orientation image, before crop and rotate), x right, y down, pixel centres at +0.5, so a mask follows
// the picture when geometry later moves it. Distances are in units of the frame diagonal D = hypot(width, height).
//
// The GPU twin is MetalMask; darkroom-engine-check proves them equal, tile seams included.

import Foundation

public struct MaskSpec: Sendable, Equatable {
    public var kind: Int
    public var invert: Bool
    public var refineRadius: Int
    public var opacity: Double
    /// The kind's parameters, in the order its enum documents (at most 8).
    public var p: [Double]

    public init(kind: Int, invert: Bool = false, refineRadius: Int = 0, opacity: Double = 1, p: [Double] = []) {
        self.kind = kind; self.invert = invert; self.refineRadius = refineRadius; self.opacity = opacity; self.p = p
    }
}

public enum Mask {
    public static let refineEps = 0.01

    /// 0 below `e0`, 1 above `e1`, smooth between; a hard step at `e0` when the edges meet or cross (feather 0).
    public static func ramp(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        guard e1 > e0 else { return x >= e0 ? 1 : 0 }
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The spec in a stack entry's blend values, or nil unless `mask_mode` is 2 with a known kind.
    public static func spec(from blend: [String: Double]) -> MaskSpec? {
        guard blend["mask_mode"] == 2, let kind = blend["mask_kind"].map({ Int($0) }) else { return nil }
        let p: [Double]
        switch kind {
        case 0: p = []
        case 1: p = MaskGradient.params(blend)
        case 2: p = MaskEllipse.params(blend)
        case 3: p = MaskLuminance.params(blend)
        case 4: p = MaskColour.params(blend)
        default: return nil
        }
        return MaskSpec(kind: kind, invert: (blend["mask_invert"] ?? 0) != 0,
                        refineRadius: max(0, Int((blend["mask_refine"] ?? 0).rounded())),
                        opacity: min(max(blend["opacity"] ?? 100, 0), 100) / 100, p: p)
    }

    /// The unrefined weight of one pixel: (x, y) its centre in frame pixels, `rgb` its working-space colour.
    public static func alpha(_ spec: MaskSpec, x: Double, y: Double, width: Double, height: Double, rgb: SIMD3<Double>) -> Double {
        let a: Double
        switch spec.kind {
        case 1: a = MaskGradient.alpha(p: spec.p, x: x, y: y, width: width, height: height)
        case 2: a = MaskEllipse.alpha(p: spec.p, x: x, y: y, width: width, height: height)
        case 3: a = MaskLuminance.alpha(p: spec.p, rgb: rgb)
        case 4: a = MaskColour.alpha(p: spec.p, rgb: rgb)
        default: a = 1
        }
        return spec.invert ? 1 - a : a
    }

    /// The finished mask over a whole image: per-pixel weights, inverted if asked, then refined to the photo's edges.
    public static func plane(_ spec: MaskSpec, rgb: [SIMD3<Double>], width: Int, height: Int) -> Plane {
        var values = [Double](repeating: 0, count: width * height)
        for i in 0..<values.count {
            values[i] = alpha(spec, x: Double(i % width) + 0.5, y: Double(i / width) + 0.5,
                              width: Double(width), height: Double(height), rgb: rgb[i])
        }
        let raw = Plane(width: width, height: height, values: values)
        guard spec.refineRadius > 0 else { return raw }
        let guide = DetailCommon.sqrtLuminance(rgb, width: width, height: height)
        return Filters.guided(guide: guide, input: raw, radius: spec.refineRadius, eps: refineEps)
    }

    /// `before` with `after` mixed in by `opacity * mask` per pixel.
    public static func blend(before: [SIMD3<Double>], after: [SIMD3<Double>], mask: Plane, opacity: Double) -> [SIMD3<Double>] {
        precondition(before.count == after.count && before.count == mask.values.count, "sizes differ")
        return (0..<before.count).map { before[$0] + (after[$0] - before[$0]) * (opacity * mask.values[$0]) }
    }

    /// Applies a masked module to a whole image: `module` runs on the input, the mask is cut from the input.
    public static func apply(_ spec: MaskSpec, to rgb: [SIMD3<Double>], width: Int, height: Int,
                             module: ([SIMD3<Double>]) -> [SIMD3<Double>]) -> [SIMD3<Double>] {
        blend(before: rgb, after: module(rgb), mask: plane(spec, rgb: rgb, width: width, height: height), opacity: spec.opacity)
    }
}
