// Method: plane geometry (orientation as a mirror/quarter-turn map, rotation about the centre, rectangle
// intersection). The largest-area inscribed rectangle uses the closed form for an axis-aligned rectangle
// inside a rotated rectangle; chart test G3 checks it against a brute-force search.
//
// The oracle for the clean engine's geometry: flip, straighten (rotate about the centre, keep a rectangle of
// the rotated bounding box), crop. Conventions checked against darktable reference renders (black box,
// dtb-selftest --stack on both engines): positive rotation turns the picture anticlockwise, an explicit
// flip is absolute from the sensor, and straighten keeps the whole bounding box unless its cl/cr/ct/cb
// fields crop it (darktable's cropmode only helps the editor pick those). Coordinates are continuous pixels with the origin at the top left and y pointing down, the
// way the UI and the stack speak. Parameter names follow darktable's flip, ashift and crop modules, read
// from the engine's introspection (names only), so one stack drives either engine.

import Foundation

/// The eight orientations, by the flip module's values: 1 flip vertically, 2 flip horizontally, 3 rotate 180,
/// 4 transpose (mirror across the main diagonal), 5 rotate 90 clockwise, 6 rotate 90 anticlockwise,
/// 7 transverse (mirror across the other diagonal). 0 and anything else is no change.
public enum Orientation: Int, Sendable, CaseIterable {
    case none = 0, flipVertical = 1, flipHorizontal = 2, rotate180 = 3
    case transpose = 4, rotateCW90 = 5, rotateCCW90 = 6, transverse = 7

    public init(value: Int) { self = Orientation(rawValue: value) ?? .none }

    /// The flip module's symbolic names, as the stack carries them.
    public init(name: String) {
        switch name {
        case "ORIENTATION_FLIP_VERTICALLY", "ORIENTATION_FLIP_Y": self = .flipVertical
        case "ORIENTATION_FLIP_HORIZONTALLY", "ORIENTATION_FLIP_X": self = .flipHorizontal
        case "ORIENTATION_ROTATE_180_DEG": self = .rotate180
        case "ORIENTATION_TRANSPOSE", "ORIENTATION_SWAP_XY": self = .transpose
        case "ORIENTATION_ROTATE_CW_90_DEG": self = .rotateCW90
        case "ORIENTATION_ROTATE_CCW_90_DEG": self = .rotateCCW90
        case "ORIENTATION_TRANSVERSE": self = .transverse
        default: self = .none
        }
    }

    public var swapsAxes: Bool { rawValue >= 4 }

    public func outputSize(_ size: SIMD2<Double>) -> SIMD2<Double> {
        swapsAxes ? SIMD2(size.y, size.x) : size
    }

    /// The flip module's symbolic name for this orientation.
    public var name: String {
        switch self {
        case .none: "ORIENTATION_NONE"
        case .flipVertical: "ORIENTATION_FLIP_VERTICALLY"
        case .flipHorizontal: "ORIENTATION_FLIP_HORIZONTALLY"
        case .rotate180: "ORIENTATION_ROTATE_180_DEG"
        case .transpose: "ORIENTATION_TRANSPOSE"
        case .rotateCW90: "ORIENTATION_ROTATE_CW_90_DEG"
        case .rotateCCW90: "ORIENTATION_ROTATE_CCW_90_DEG"
        case .transverse: "ORIENTATION_TRANSVERSE"
        }
    }

    /// This orientation followed by `next`, as one orientation (the eight form a group). Found by
    /// matching where three points of a non-square image land, so it needs no table of its own.
    public func then(_ next: Orientation) -> Orientation {
        let size = SIMD2<Double>(5, 3)
        let points = [SIMD2<Double>(0, 0), SIMD2(5, 0), SIMD2(0, 3)]
        let mid = outputSize(size)
        let want = points.map { next.map(map($0, size: size), size: mid) }
        return Orientation.allCases.first { c in zip(points, want).allSatisfy { c.map($0, size: size) == $1 } } ?? .none
    }

    /// Where a point of a `size` image lands.
    public func map(_ p: SIMD2<Double>, size: SIMD2<Double>) -> SIMD2<Double> {
        let w = size.x, h = size.y
        switch self {
        case .none: return p
        case .flipVertical: return SIMD2(p.x, h - p.y)
        case .flipHorizontal: return SIMD2(w - p.x, p.y)
        case .rotate180: return SIMD2(w - p.x, h - p.y)
        case .transpose: return SIMD2(p.y, p.x)
        case .rotateCW90: return SIMD2(h - p.y, p.x)
        case .rotateCCW90: return SIMD2(p.y, w - p.x)
        case .transverse: return SIMD2(h - p.y, w - p.x)
        }
    }
}

/// How the editor picks straighten's crop: not at all (the bounding box, corners empty), the largest-area
/// rectangle inside the image, or the largest rectangle with the original aspect ratio. See `cropFractions`.
public enum StraightenCrop: Int, Sendable {
    case off = 0, largest = 1, aspect = 2

    public init(name: String) {
        switch name {
        case "ASHIFT_CROP_OFF": self = .off
        case "ASHIFT_CROP_ASPECT": self = .aspect
        default: self = .largest
        }
    }
}

public enum Straighten {
    /// Rotation about the centre by `degrees`, positive anticlockwise on screen (y down), as darktable turns it.
    public static func rotate(_ p: SIMD2<Double>, size: SIMD2<Double>, degrees: Double) -> SIMD2<Double> {
        let a = degrees * .pi / 180
        let c = size / 2, d = p - c
        return c + SIMD2(d.x * cos(a) + d.y * sin(a), -d.x * sin(a) + d.y * cos(a))
    }

    /// The bounding box of a `size` image rotated by `degrees`.
    public static func boundingSize(_ size: SIMD2<Double>, degrees: Double) -> SIMD2<Double> {
        let a = degrees * .pi / 180, s = abs(sin(a)), c = abs(cos(a))
        return SIMD2(size.x * c + size.y * s, size.x * s + size.y * c)
    }

    /// The largest axis-aligned rectangle, centred, that fits inside a `size` image rotated by `degrees`.
    public static func inscribedSize(_ size: SIMD2<Double>, degrees: Double, mode: StraightenCrop) -> SIMD2<Double> {
        let w = size.x, h = size.y
        guard w > 0, h > 0 else { return .zero }
        let a = degrees * .pi / 180, s = abs(sin(a)), c = abs(cos(a))
        switch mode {
        case .off:
            return boundingSize(size, degrees: degrees)
        case .aspect:
            // scale k of the original rectangle: k (w c + h s) <= w and k (w s + h c) <= h
            let k = min(w / (w * c + h * s), h / (w * s + h * c))
            return SIMD2(w * k, h * k)
        case .largest:
            if s < 1e-12 { return size }
            let long = max(w, h), short = min(w, h)
            if short <= 2 * s * c * long || abs(s - c) < 1e-10 {
                // half constrained: two corners of the rectangle touch the long sides
                let x = 0.5 * short
                return w >= h ? SIMD2(x / s, x / c) : SIMD2(x / c, x / s)
            }
            // fully constrained: all four corners touch the sides
            let c2 = c * c - s * s
            return SIMD2((w * c - h * s) / c2, (h * c - w * s) / c2)
        }
    }

    /// Straighten's crop for `mode`, as fractions of the rotated bounding box (cl, ct, cr, cb): the centred
    /// inscribed rectangle. What the editor writes into the stack when the user straightens.
    public static func cropFractions(_ size: SIMD2<Double>, degrees: Double, mode: StraightenCrop) -> CropRect {
        let box = boundingSize(size, degrees: degrees), keep = inscribedSize(size, degrees: degrees, mode: mode)
        guard box.x > 0, box.y > 0 else { return .full }
        let l = (box.x - keep.x) / 2 / box.x, t = (box.y - keep.y) / 2 / box.y
        return CropRect(left: l, top: t, right: 1 - l, bottom: 1 - t)
    }

    /// Whether `p` lies inside a `size` image rotated by `degrees` about its centre (for G3's search).
    public static func insideRotated(_ p: SIMD2<Double>, size: SIMD2<Double>, degrees: Double) -> Bool {
        // undo the rotation and test against the original rectangle
        let q = rotate(p, size: size, degrees: -degrees)
        return q.x >= -1e-9 && q.y >= -1e-9 && q.x <= size.x + 1e-9 && q.y <= size.y + 1e-9
    }
}

/// The crop module's rectangle: left, top, right, bottom as fractions of the image it receives.
public struct CropRect: Sendable, Equatable {
    public var left: Double, top: Double, right: Double, bottom: Double

    /// Clamped to 0...1. An edge pair closer than 1% means "no crop on that axis", so a zeroed entry
    /// (right = bottom = 0) is the full frame rather than nothing.
    public init(left: Double, top: Double, right: Double, bottom: Double) {
        func c(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
        var l = c(left), t = c(top), r = c(right), b = c(bottom)
        if r - l < 0.01 { l = 0; r = 1 }
        if b - t < 0.01 { t = 0; b = 1 }
        self.left = l; self.top = t; self.right = r; self.bottom = b
    }

    public static let full = CropRect(left: 0, top: 0, right: 1, bottom: 1)

    /// The largest centred crop with the aspect `longOverShort` (1 is square, 1.25 is 4:5, 1.5 is 3:2) inside
    /// a `size` image, turned to match it: a landscape image gets a landscape crop, a portrait one a portrait crop.
    public static func centred(longOverShort ratio: Double, in size: SIMD2<Double>) -> CropRect {
        guard ratio.isFinite, ratio >= 1, size.x > 0, size.y > 0 else { return .full }
        let target = size.x >= size.y ? ratio : 1 / ratio          // width over height
        let w = min(size.x, size.y * target), h = w / target
        let l = (1 - w / size.x) / 2, t = (1 - h / size.y) / 2
        return CropRect(left: l, top: t, right: 1 - l, bottom: 1 - t)
    }
}

/// The three steps in darktable's order: straighten (in the sensor's orientation), flip (the camera's
/// orientation unless the stack sets one), crop (in the final orientation). The order was read off
/// reference renders: a straighten crop only matches darktable's output shape when it comes before flip.
public struct GeometrySpec: Sendable, Equatable {
    public var orientation: Orientation = .none
    public var degrees: Double = 0
    /// Straighten's crop of the rotated bounding box (darktable's cl, ct, cr, cb).
    public var straightenCrop: CropRect = .full
    public var crop: CropRect = .full

    public init(orientation: Orientation = .none, degrees: Double = 0, straightenCrop: CropRect = .full,
                crop: CropRect = .full) {
        self.orientation = orientation
        self.degrees = degrees.isFinite ? degrees : 0
        self.straightenCrop = straightenCrop
        self.crop = crop
    }

    public var isIdentity: Bool { orientation == .none && degrees == 0 && straightenCrop == .full && crop == .full }

    /// The rectangle straighten keeps, in the coordinates of the input rotated about its centre.
    public func straightenRect(_ input: SIMD2<Double>) -> (origin: SIMD2<Double>, size: SIMD2<Double>) {
        let box = Straighten.boundingSize(input, degrees: degrees)
        let c = straightenCrop
        let origin = input / 2 - box / 2 + SIMD2(box.x * c.left, box.y * c.top)
        return (origin, SIMD2(box.x * (c.right - c.left), box.y * (c.bottom - c.top)))
    }

    /// The output size for a `size` input, before rounding to pixels.
    public func outputSize(_ size: SIMD2<Double>) -> SIMD2<Double> {
        let oriented = orientation.outputSize(straightenRect(size).size)
        return SIMD2(oriented.x * (crop.right - crop.left), oriented.y * (crop.bottom - crop.top))
    }

    /// Where a point of the input lands in the output (output origin at the top left of the crop).
    public func map(_ p: SIMD2<Double>, size: SIMD2<Double>) -> SIMD2<Double> {
        let (origin, kept) = straightenRect(size)
        let inKept = Straighten.rotate(p, size: size, degrees: degrees) - origin
        let oriented = orientation.map(inKept, size: kept)
        let orientedSize = orientation.outputSize(kept)
        return oriented - SIMD2(orientedSize.x * crop.left, orientedSize.y * crop.top)
    }
}
