// Method: Apple Core Image documentation (CIImage transformed(by:), clampedToExtent, cropped(to:)) and
// DarkroomCore's Geometry oracle, whose point map this file turns into one affine transform.
//
// Flip, straighten and crop for the clean engine. The maths lives in DarkroomCore.GeometrySpec; here it
// is read back as an affine map (three mapped points give the linear part and the offset) and handed
// to Core Image, so the engine and the oracle cannot drift apart. Geometry runs after the per-pixel
// stack: per-pixel edits commute with it, and region renders keep working because Core Image only
// computes the tiles a crop asks for.

import CoreImage
import DarkroomCore
import DarkroomEngineAPI
import Foundation

enum CIGeometry {
    /// The stack operations that are geometry, not per-pixel modules.
    static let operations: Set<String> = ["flip", "ashift", "crop"]

    /// The camera's EXIF orientation as the turn or mirror that shows the sensor image upright.
    /// darkroom-engine-check G-X compares each one with Core Image's own `oriented(_:)`.
    static func orientation(exif: CGImagePropertyOrientation) -> Orientation {
        switch exif {
        case .up: .none
        case .upMirrored: .flipHorizontal
        case .down: .rotate180
        case .downMirrored: .flipVertical
        case .leftMirrored: .transpose
        case .right: .rotateCW90
        case .rightMirrored: .transverse
        case .left: .rotateCCW90
        @unknown default: .none
        }
    }

    /// Reads the enabled geometry entries for an image the decoder hands over in sensor orientation.
    /// The flip is the camera's unless the stack sets one: darktable's flip is absolute from the sensor,
    /// and ORIENTATION_NULL means "the camera's". Straighten fields the clean engine does not do yet
    /// (lens shift, shear) are an error, never a silent skip.
    static func spec(_ stack: [StackEntry], camera: Orientation) throws -> GeometrySpec {
        var spec = GeometrySpec(orientation: camera)
        for e in stack where e.enabled {
            switch e.operation {
            case "flip":
                switch e.params["orientation"] {
                case .option(let name)? where name != "ORIENTATION_NULL": spec.orientation = Orientation(name: name)
                case .number(let v)? where v >= 0: spec.orientation = Orientation(value: Int(v))
                default: break
                }
            case "ashift":
                for f in ["lensshift_v", "lensshift_h", "shear"] {
                    if let v = e.params[f]?.double, abs(v) > 1e-9 {
                        throw EngineError("the clean engine has no \(f.replacingOccurrences(of: "_", with: " ")) yet")
                    }
                }
                spec.degrees = e.params["rotation"]?.double ?? 0
                // cropmode only tells the editor how to pick these; the engine keeps what they say
                spec.straightenCrop = CropRect(left: e.params["cl"]?.double ?? 0, top: e.params["ct"]?.double ?? 0,
                                               right: e.params["cr"]?.double ?? 1, bottom: e.params["cb"]?.double ?? 1)
            case "crop":
                spec.crop = CropRect(left: e.params["cx"]?.double ?? 0, top: e.params["cy"]?.double ?? 0,
                                     right: e.params["cw"]?.double ?? 1, bottom: e.params["ch"]?.double ?? 1)
            default:
                break
            }
        }
        spec.degrees = spec.degrees.isFinite ? min(max(spec.degrees, -180), 180) : 0
        return spec
    }

    /// The output size in pixels for an input of `size`, rounded as `apply` rounds it.
    static func pixelSize(_ spec: GeometrySpec, input size: CGSize) -> (width: Int, height: Int) {
        let out = spec.outputSize(SIMD2(Double(size.width), Double(size.height)))
        return (max(1, Int(out.x.rounded())), max(1, Int(out.y.rounded())))
    }

    /// Applies `spec` to `image`. The result's extent starts at (0, 0).
    static func apply(_ spec: GeometrySpec, to image: CIImage) -> CIImage {
        guard !spec.isIdentity else { return image }
        let ext = image.extent
        let size = SIMD2(Double(ext.width), Double(ext.height))
        // the oracle's map, top-left origin, as q = A p + b
        let b = spec.map(.zero, size: size)
        let ax = spec.map(SIMD2(1, 0), size: size) - b
        let ay = spec.map(SIMD2(0, 1), size: size) - b
        let (w, h) = pixelSize(spec, input: ext.size)
        // Core Image is bottom-left origin: p = (X - minX, maxY - Y) in, Q = (q.x, h - q.y) out
        let toTopLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -ext.minX, ty: ext.maxY)
        let oracle = CGAffineTransform(a: ax.x, b: ax.y, c: ay.x, d: ay.y, tx: b.x, ty: b.y)
        let toBottomLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(h))
        let t = toTopLeft.concatenating(oracle).concatenating(toBottomLeft)
        // without rotation, clamp first so edge pixels are not mixed with the transparent outside; with it,
        // whatever lies outside the picture stays empty, as darktable shows it
        let source = spec.degrees != 0 ? image : image.clampedToExtent()
        return source.transformed(by: t).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }
}
