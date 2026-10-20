// Method: Apple Core Image documentation (CIImage from bitmap data, CIContext render to bitmap).
//
// Runs a stack through the engine's own `CIEngine.applyStack` on pixels the caller supplies, with no RAW
// decode, so darkroom-engine-check can compare the engine path against the DarkroomCore oracle.

import CoreImage
import DarkroomEngineAPI
import Foundation
import Metal

public enum CIEngineProbe {
    /// `pixels` are RGBA float in the engine's working space (extended linear sRGB), `width` by `height`.
    /// Returns the rendered pixels in the same space and layout, with no colour management on the way out.
    public static func render(stack: [StackEntry], pixels: [SIMD4<Float>], width: Int, height: Int) throws -> [SIMD4<Float>] {
        guard pixels.count == width * height, width > 0, height > 0 else { throw EngineError("probe: size mismatch") }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let device = MTLCreateSystemDefaultDevice() else { throw EngineError("probe: no colour space or device") }
        let rowBytes = width * MemoryLayout<SIMD4<Float>>.stride
        let data = pixels.withUnsafeBytes { Data($0) }
        let input = CIImage(bitmapData: data, bytesPerRow: rowBytes, size: CGSize(width: width, height: height),
                            format: .RGBAf, colorSpace: space)
        let output = try CIEngine.applyStack(input, stack)
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
        ])
        var out = [SIMD4<Float>](repeating: .zero, count: pixels.count)
        out.withUnsafeMutableBytes { buf in
            context.render(output, toBitmap: buf.baseAddress!, rowBytes: rowBytes,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: space)
        }
        return out
    }

    /// Whether the engine would decode scene-linear for this stack.
    public static func wantsSceneLinear(_ stack: [StackEntry]) -> Bool {
        CIEngine.wantsSceneLinear(stack)
    }
}
