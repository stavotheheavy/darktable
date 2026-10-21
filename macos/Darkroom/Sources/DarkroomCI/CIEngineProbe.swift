// Method: Apple Core Image documentation (CIImage from bitmap data, CIContext render to bitmap).
//
// Runs a stack through the engine's own `CIEngine.applyStack` on pixels the caller supplies, with no RAW
// decode, so darkroom-engine-check can compare the engine path against the DarkroomCore oracle.

import CoreImage
import DarkroomCore
import DarkroomEngineAPI
import DarkroomMetal
import Foundation
import Metal

public enum CIEngineProbe {
    /// The engine's working space (linear Rec.2020), for callers that build their own contexts.
    public static var workingColorSpace: CGColorSpace { CIEngine.workingSpace }

    /// `pixels` are RGBA float in the engine's working space (extended linear sRGB), `width` by `height`.
    /// Returns the rendered pixels in the same space and layout, with no colour management on the way out.
    public static func render(stack: [StackEntry], pixels: [SIMD4<Float>], width: Int, height: Int, scale: Double = 1) throws -> [SIMD4<Float>] {
        try renderSized(stack: stack, pixels: pixels, width: width, height: height, scale: scale).pixels
    }

    /// Like `render`, for stacks that change the size: returns the output pixels and their size.
    public static func renderSized(stack: [StackEntry], pixels: [SIMD4<Float>], width: Int, height: Int,
                                   camera: Orientation = .none, coreImageOrientation: UInt32? = nil, scale: Double = 1,
                                   rasters: [MaskPicture] = [], fuse: Bool = true) throws
        -> (pixels: [SIMD4<Float>], width: Int, height: Int) {
        guard pixels.count == width * height, width > 0, height > 0 else { throw EngineError("probe: size mismatch") }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
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
            output = try CIEngine.process(input, stack, camera: camera, scale: scale, rasters: Dictionary(rasters.map { ($0.id, MaskRaster(id: $0.id, width: $0.width, height: $0.height, pixels: $0.pixels)) }) { $1 }, fuse: fuse)
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

    /// Renders `stack` as the HDR export does: the SDR picture and an HDR version (display transform peak `headroom`),
    /// written as a JPEG with a gain map. For darkroom-engine-check's T10.
    public static func hdrJPEG(stack: [StackEntry], pixels: [SIMD4<Float>], width: Int, height: Int, headroom: Double) throws -> Data {
        guard pixels.count == width * height, let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
              let device = MTLCreateSystemDefaultDevice() else { throw EngineError("probe: bad input") }
        let input = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        let sdr = try CIEngine.process(input, stack, camera: .none)
        let hdr = try CIEngine.process(input, stack, camera: .none, hdrPeak: headroom)
        return try CIEngine.hdrJPEG(context: context, sdr: sdr, hdr: hdr, headroom: headroom)
    }

    /// `render` with the HDR peak: the pixels a viewer with `headroom` of display headroom should see (linear, unclamped).
    public static func renderHDR(stack: [StackEntry], pixels: [SIMD4<Float>], width: Int, height: Int, headroom: Double) throws -> [SIMD4<Float>] {
        guard pixels.count == width * height, let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
              let device = MTLCreateSystemDefaultDevice() else { throw EngineError("probe: bad input") }
        let input = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
        let output = try CIEngine.process(input, stack, camera: .none, hdrPeak: headroom)
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        var out = [SIMD4<Float>](repeating: .zero, count: width * height)
        out.withUnsafeMutableBytes { buf in
            context.render(output, toBitmap: buf.baseAddress!, rowBytes: width * 16, bounds: output.extent, format: .RGBAf, colorSpace: space)
        }
        return out
    }

    /// The neighbourhood filters the detail modules use, for darkroom-engine-check's F-E series.
    public enum Filter: Sendable { case box(Int), atrous(Int), guided(Int, Double), sqrtLuminance, sqrtLuminanceRoundTrip, mask(MaskSpec), min(Int), clipping }

    /// Like `render`, but renders only `region` (x, y, width, height, top-left origin) of the output, so a module's
    /// tile seams can be compared with the full frame (darkroom-engine-check F-E4 does this for the bare filters).
    public static func renderRegion(stack: [StackEntry], pixels: [SIMD4<Float>], width: Int, height: Int,
                                    region: (x: Int, y: Int, w: Int, h: Int), rasters: [MaskPicture] = []) throws -> [SIMD4<Float>] {
        guard pixels.count == width * height, let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
              let device = MTLCreateSystemDefaultDevice() else { throw EngineError("probe: bad input") }
        let input = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
        let output = try CIEngine.process(input, stack, camera: .none,
                                           rasters: Dictionary(rasters.map { ($0.id, MaskRaster(id: $0.id, width: $0.width, height: $0.height, pixels: $0.pixels)) }) { $1 })
        let r = region
        let bounds = CGRect(x: r.x, y: height - r.y - r.h, width: r.w, height: r.h)
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        var out = [SIMD4<Float>](repeating: .zero, count: r.w * r.h)
        out.withUnsafeMutableBytes { buf in
            context.render(output, toBitmap: buf.baseAddress!, rowBytes: r.w * 16, bounds: bounds, format: .RGBAf, colorSpace: space)
        }
        return out
    }

    /// Runs `filter` through Core Image on `pixels` and renders the whole frame, or only `region` (x, y, width,
    /// height, top-left origin) so tile seams can be compared with the full frame.
    public static func filter(_ filter: Filter, pixels: [SIMD4<Float>], width: Int, height: Int,
                              region: (x: Int, y: Int, w: Int, h: Int)? = nil) throws -> [SIMD4<Float>] {
        guard pixels.count == width * height, let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
              let device = MTLCreateSystemDefaultDevice() else { throw EngineError("probe: bad input") }
        let input = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
        let output: CIImage
        switch filter {
        case .box(let r): output = try CIBridge.boxMean(input, radius: r)
        case .atrous(let level): output = try CIBridge.atrousSmooth(input, level: level)
        case .guided(let r, let eps): output = try CIBridge.guided(input, radius: r, eps: eps)
        case .sqrtLuminance: output = try CIBridge.sqrtLuminance(input)
        case .min(let r): output = try CIBridge.minFilter(input, radius: r)
        case .clipping: output = try CIBridge.clippingOverlay(input)
        case .mask(let spec): output = try CIBridge.localMask(input, spec: spec)   // (a, a, a, 1)
        case .sqrtLuminanceRoundTrip:
            output = try CIBridge.applying(sqrtLuminance: try CIBridge.sqrtLuminance(input), to: input)
        }
        let r = region ?? (0, 0, width, height)
        // top-left region to Core Image's bottom-left coordinates
        let bounds = CGRect(x: r.x, y: height - r.y - r.h, width: r.w, height: r.h)
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        var out = [SIMD4<Float>](repeating: .zero, count: r.w * r.h)
        out.withUnsafeMutableBytes { buf in
            context.render(output, toBitmap: buf.baseAddress!, rowBytes: r.w * 16, bounds: bounds, format: .RGBAf, colorSpace: space)
        }
        return out
    }

    private static let goldenOverrides: [String: [String: Double]] = [
        // the settings the display golden is rendered at: a little contrast, the default white point and path to white, no lift
        // a lift of the shadows, a pull on the highlights and a rise of one zone, at a radius that fits the 48 by 40 fixture
        // modules whose defaults do nothing: the golden must exercise the maths (these four were identity goldens, which guard nothing)
        "chromalimit": ["limit": 0.1],
        "highlightrolloff": ["white": 1, "knee": 0.4, "amount": 1],
        "deband": ["radius": 9, "threshold": 0.05, "strength": 1],
        "skinsmooth": ["amount": 1, "radius": 8, "hue": 140, "width": 90],
        "zones": ["shadows": 1.2, "highlights": -1, "blacks": 0.5, "z_p1": 0.4, "scale": 0.1],
        "graduated": ["exposure": -1.2, "position": 0.45, "angle": -70, "feather": 0.4],
        // the fixture's corner patch (3.2, 2.6, 1.9) is clipped in some channels at this level
        "highlights": ["clip": 2, "strength": 1],
        "display": ["exposure": 0, "contrast": 30, "white": 4.5, "purity": 0.5],
        "hazeremoval": ["strength": 1, "radius": 3, "airlight": 1],
        // a point curve with an S, a raised black point and a lowered white point
        "tonecurve": ["n": 6, "x0": 0.04, "x1": 0.22, "x2": 0.45, "x3": 0.68, "x4": 0.85, "x5": 0.97,
                      "y0": 0.06, "y1": 0.15, "y2": 0.42, "y3": 0.72, "y4": 0.9, "y5": 0.96],
    ]

    /// Every catalogue module's operation and display name, for the parity list's checks.
    public static func catalogue() -> [(operation: String, name: String)] {
        CIModule.all.map { ($0.operation, $0.name) }
    }

    /// One stack per catalogue module for the golden-image suite (T11): the module on, every float field moved halfway
    /// from its default to the end of its range that is further away. Derived from the schema, so a module that is added
    /// has a golden case without anyone writing one. Geometry modules change the picture's size and have their own checks.
    public static func goldenCases() -> [(operation: String, version: Int, stack: [StackEntry])] {
        CIModule.all.filter { !$0.geometry }.sorted { $0.operation < $1.operation }.map { m in
            var params: [String: ParamValue] = [:]
            for f in m.fields where f.kind == .float || f.kind == .int {
                let d = f.defaultValue.double ?? 0
                let far = (f.max - d) >= (d - f.min) ? f.max : f.min
                var v = d + 0.5 * (far - d)
                if f.kind == .int { v = v.rounded() }
                params[f.name] = .number(v)
            }
            // schema-derived settings can make a module a no-op on the small fixture (a haze patch as wide as the frame)
            for (name, value) in Self.goldenOverrides[m.operation] ?? [:] { params[name] = .number(value) }
            return (m.operation, m.algorithmVersion, [StackEntry(operation: m.operation, params: params)])
        }
    }

    /// The engine's reading of a camera EXIF orientation value (1...8).
    public static func orientation(exif raw: UInt32) -> Orientation {
        CGImagePropertyOrientation(rawValue: raw).map(CIGeometry.orientation(exif:)) ?? .none
    }

    /// The operations that run after the display transform when it is on.
    public static var displayReferredOperations: Set<String> { CIModule.displayReferredOperations }

    /// The stack a session or export render actually runs (see CIModule.withDefaults).
    public static func withDefaults(_ stack: [StackEntry]) -> [StackEntry] { CIModule.withDefaults(stack) }

    /// The operations whose modules fuse into one pass.
    public static var fusableOperations: Set<String> { CIModule.fusableOperations }

    /// How many ops each fused pass of `stack` holds, in pipeline order (what the engine would dispatch). A neighbourhood module or a
    /// module that is masked or faded ends a run.
    public static func fusedRunLengths(_ stack: [StackEntry]) -> [Int] {
        let ordered = stack.filter { $0.enabled && !CIGeometry.operations.contains($0.operation) }.compactMap { e in CIModule.named(e.operation).map { ($0, e) } }
            .sorted { CIEngine.effectiveOrder($0.0, sceneReferred: CIEngine.wantsSceneLinear(stack)) < CIEngine.effectiveOrder($1.0, sceneReferred: CIEngine.wantsSceneLinear(stack)) }
        var runs: [Int] = [], current = 0
        for (m, e) in ordered {
            let maskMode = e.blend["mask_mode"]?.double ?? 0
            if maskMode == 0, (e.blend["opacity"]?.double ?? 100) >= 100, CIModule.fusableOperations.contains(m.operation) {
                if CIModule.fusedOp(m.operation, m.values(from: e.params)) != nil { current += 1 }
            } else {
                if current > 0 { runs.append(current); current = 0 }
            }
        }
        if current > 0 { runs.append(current) }
        return runs
    }

    /// Whether the engine would decode scene-linear for this stack.
    public static func wantsSceneLinear(_ stack: [StackEntry]) -> Bool {
        CIEngine.wantsSceneLinear(stack)
    }
}

/// A segment cache on pixels the caller supplies, for darkroom-engine-check: the same `CIEngine.applyStack` the app runs, in the very
/// context the app builds (`CIEngine.makeContext`), so the check sees what a session render sees.
public final class SegmentProbe {
    private let context: CIContext
    private let space: CGColorSpace
    private let cache: SegmentCache
    private let device: MTLDevice

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw EngineError("probe: no device") }
        let made = CIEngine.makeContext(device: device)
        guard let space = made.workingColorSpace else { throw EngineError("probe: no working space") }
        self.device = device; self.context = made; self.space = space
        self.cache = SegmentCache(context: made, device: device, space: space)
    }

    public var hits: Int { cache.hits }
    public var misses: Int { cache.misses }
    public var entries: Int { cache.count }

    /// Renders `stack` over `pixels`, through the cache unless `cached` is false.
    public func render(stack: [StackEntry], pixels: [SIMD4<Float>], width: Int, height: Int, cached: Bool = true) throws -> [SIMD4<Float>] {
        guard pixels.count == width * height else { throw EngineError("probe: size mismatch") }
        let input = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
        let output = try CIEngine.process(input, stack, camera: .none, scale: 1,
                                          segments: cached ? CIEngine.Segments(cache: cache, base: "probe|\(width)x\(height)") : nil)
        var out = [SIMD4<Float>](repeating: .zero, count: width * height)
        out.withUnsafeMutableBytes { buf in
            context.render(output, toBitmap: buf.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: space)
        }
        return out
    }

    /// A source image for `timeFrame`, built once: the app's decode stays resident between frames, so a timing must not pay a bitmap upload per frame.
    public func makeSource(pixels: [SIMD4<Float>], width: Int, height: Int) -> CIImage {
        CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
    }

    /// Milliseconds to turn `stack` over `source` into the viewport's 8-bit sRGB frame, as `CIEngine.frame` does (a createCGImage
    /// read-back), through the cache.
    public func timeFrame(stack: [StackEntry], source: CIImage) throws -> Double {
        let w = Int(source.extent.width), h = Int(source.extent.height)
        let started = ContinuousClock.now
        let output = try CIEngine.process(source, stack, camera: .none, scale: 1,
                                          segments: CIEngine.Segments(cache: cache, base: "time|\(w)x\(h)"))
        guard context.createCGImage(output, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) != nil else { throw EngineError("probe: no frame") }
        let d = started.duration(to: .now)
        return Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1_000_000_000_000_000
    }

    /// The 8-bit sRGB codes (red channel, one row) of a horizontal ramp or any pixels, as the viewport makes them, with or without the dither.
    public func codes8(pixels: [SIMD4<Float>], width: Int, height: Int, dither: Bool) throws -> [UInt8] {
        let source = makeSource(pixels: pixels, width: width, height: height)
        let image = dither ? try CIBridge.dither8(source) : source
        guard let cg = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw EngineError("probe: no frame") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let c = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EngineError("probe: no context")
        }
        c.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }
    }
}
