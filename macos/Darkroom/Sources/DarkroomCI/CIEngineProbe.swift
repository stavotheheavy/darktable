// Method: Apple Core Image documentation (CIImage from bitmap data, CIContext render to bitmap).
//
// Runs a stack through the engine's own `CIEngine.applyStack` on pixels the caller supplies, with no RAW
// decode, so darkroom-engine-check can compare the engine path against the DarkroomCore oracle.

import CoreImage
import DarkroomCore
import DarkroomEngineAPI
import Foundation
import Metal

public enum CIEngineProbe {
    /// `pixels` are RGBA float in the engine's working space (extended linear sRGB), `width` by `height`.
    /// Returns the rendered pixels in the same space and layout, with no colour management on the way out.
    public static func render(stack: [StackEntry], pixels: [SIMD4<Float>], width: Int, height: Int) throws -> [SIMD4<Float>] {
        try renderSized(stack: stack, pixels: pixels, width: width, height: height).pixels
    }

    /// Like `render`, for stacks that change the size: returns the output pixels and their size.
    public static func renderSized(stack: [StackEntry], pixels: [SIMD4<Float>], width: Int, height: Int,
                                   camera: Orientation = .none, coreImageOrientation: UInt32? = nil) throws
        -> (pixels: [SIMD4<Float>], width: Int, height: Int) {
        guard pixels.count == width * height, width > 0, height > 0 else { throw EngineError("probe: size mismatch") }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let device = MTLCreateSystemDefaultDevice() else { throw EngineError("probe: no colour space or device") }
        let rowBytes = width * MemoryLayout<SIMD4<Float>>.stride
        let data = pixels.withUnsafeBytes { Data($0) }
        let input = CIImage(bitmapData: data, bytesPerRow: rowBytes, size: CGSize(width: width, height: height),
                            format: .RGBAf, colorSpace: space)
        // with `coreImageOrientation`, Core Image's own EXIF orienting replaces the engine (for check G-X)
        let output: CIImage
        if let raw = coreImageOrientation {
            guard let o = CGImagePropertyOrientation(rawValue: raw) else { throw EngineError("probe: bad orientation") }
            let turned = input.oriented(o)
            output = turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
        } else {
            output = try CIEngine.process(input, stack, camera: camera)
        }
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
        ])
        let ext = output.extent.integral
        let ow = Int(ext.width), oh = Int(ext.height)
        var out = [SIMD4<Float>](repeating: .zero, count: ow * oh)
        out.withUnsafeMutableBytes { buf in
            context.render(output, toBitmap: buf.baseAddress!, rowBytes: ow * MemoryLayout<SIMD4<Float>>.stride,
                           bounds: ext, format: .RGBAf, colorSpace: space)
        }
        return (out, ow, oh)
    }

    /// The engine's reading of a camera EXIF orientation value (1...8).
    public static func orientation(exif raw: UInt32) -> Orientation {
        CGImagePropertyOrientation(rawValue: raw).map(CIGeometry.orientation(exif:)) ?? .none
    }

    /// Whether the engine would decode scene-linear for this stack.
    public static func wantsSceneLinear(_ stack: [StackEntry]) -> Bool {
        CIEngine.wantsSceneLinear(stack)
    }
}
