// Method: Apple Core Image documentation, CIImageProcessorKernel (custom Metal processing inside a Core Image graph).
//
// The bridge between the oracle-checked kernels and the engine the app runs. Each kernel here is a texture
// entry point that calls the same Metal functions as its buffer twin (MetalEdit, MetalToneDisplay), so
// darkroom-metal-check covers the maths and darkroom-engine-check covers the wiring. Core Image keeps the
// graph: tiling, scaling, regions and the intermediate cache. Every new module card adds its kernel here.

import CoreImage
import DarkroomCore
import Metal

public enum CIBridgeError: Error {
    case noDevice
    case noKernel(String)
    case badArguments
    /// A spatial kernel got a region of a size it did not ask for (it would read the wrong neighbours).
    case regionMismatch(input: CGRect, output: CGRect)
}

/// The pipelines the bridge runs, compiled once from the buffer kernels' own sources plus the texture
/// entry points below.
final class BridgeKernels: @unchecked Sendable {
    static let shared: Result<BridgeKernels, Error> = Result { try BridgeKernels() }

    let device: MTLDevice
    private let library: MTLLibrary
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()
    private var toneTables: [SIMD2<Double>: MTLBuffer] = [:]
    /// Libraries compiled from a card's own source, keyed by that source.
    private var cardLibraries: [String: MTLLibrary] = [:]
    private var cardPipelines: [String: MTLComputePipelineState] = [:]

    static let textureSource = #"""
    // texture entry points; the per-pixel maths lives in the buffer kernels' shared functions above
    kernel void gainTex(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float4 &scale [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(gid);
        dst.write(float4(c.rgb * scale.rgb, c.a), gid);
    }

    // tone and display, leaving display-linear sRGB in 0...1: Core Image encodes it on output
    kernel void toneDisplayLinearTex(texture2d<float, access::read> src [[texture(0)]],
                                     texture2d<float, access::write> dst [[texture(1)]],
                                     constant float4 &params [[buffer(0)]],
                                     constant float4 *columns [[buffer(1)]],
                                     device const float *table [[buffer(2)]],
                                     constant float &peak [[buffer(3)]],
                                     uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(gid);
        float3 toned = float3(toneLookup(c.r, params, table),
                              toneLookup(c.g, params, table),
                              toneLookup(c.b, params, table));
        float3x3 m = float3x3(columns[0].xyz, columns[1].xyz, columns[2].xyz);
        dst.write(float4(clamp(m * toned, 0.0f, peak), c.a), gid);   // peak 1 = SDR; an HDR render lets highlights past 1
    }
    """#

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CIBridgeError.noDevice }
        self.device = device
        let source = [MetalExposureWB.source, MetalToneDisplay.source, Self.textureSource].joined(separator: "\n")
        library = try device.makeLibrary(source: source, options: nil)
    }

    func pipeline(_ name: String) throws -> MTLComputePipelineState {
        lock.lock()
        defer { lock.unlock() }
        if let p = pipelines[name] { return p }
        guard let f = library.makeFunction(name: name) else { throw CIBridgeError.noKernel(name) }
        let p = try device.makeComputePipelineState(function: f)
        pipelines[name] = p
        return p
    }

    /// A pipeline from a card's own Metal source (compiled once per source, then cached by function name).
    func pipeline(_ name: String, source: String) throws -> MTLComputePipelineState {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(source.hashValue):\(name)"
        if let p = cardPipelines[key] { return p }
        let library: MTLLibrary
        if let l = cardLibraries[source] { library = l } else {
            library = try device.makeLibrary(source: source, options: nil)
            cardLibraries[source] = library
        }
        guard let f = library.makeFunction(name: name) else { throw CIBridgeError.noKernel(name) }
        let p = try device.makeComputePipelineState(function: f)
        cardPipelines[key] = p
        return p
    }

    /// The ToneMap table for one contrast value, uploaded once and reused.
    func toneTable(contrast: Double, peak: Double = 1) -> MTLBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let key = SIMD2(contrast, peak)
        if let b = toneTables[key] { return b }
        let table = ToneMap(contrast: contrast, peak: peak).table.map { Float($0) }
        let b = device.makeBuffer(bytes: table, length: table.count * MemoryLayout<Float>.stride, options: .storageModeShared)
        if toneTables.count > 32 { toneTables.removeAll() }
        toneTables[key] = b
        return b
    }

    /// Encodes `name` over the output texture with `bind` setting its buffers (textures 0 and 1 are set here).
    func dispatch(_ name: String, source: String? = nil, input: CIImageProcessorInput, output: CIImageProcessorOutput,
                  bind: (MTLComputeCommandEncoder) throws -> Void) throws {
        let p = try source.map { try pipeline(name, source: $0) } ?? pipeline(name)
        guard let cmd = output.metalCommandBuffer, var src = input.metalTexture, let dst = output.metalTexture else {
            throw CIBridgeError.badArguments
        }
        // Core Image hands a LARGER input texture than the output when one image feeds several consumers that need
        // different regions (a masked module: its input also feeds the mask's guided filter). These kernels read the
        // input at gid, so crop it to the output's rectangle first. Everything is checked before an encoder exists:
        // an encoder dropped without endEncoding crashes the process.
        let off = textureOffset(input: input.region, output: output.region)
        if off != SIMD2<Int32>(0, 0) || src.width != dst.width || src.height != dst.height {
            guard input.region.contains(output.region), off.x >= 0, off.y >= 0,
                  Int(off.x) + dst.width <= src.width, Int(off.y) + dst.height <= src.height else {
                throw CIBridgeError.regionMismatch(input: input.region, output: output.region)
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat, width: dst.width, height: dst.height, mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .private
            guard let cropped = device.makeTexture(descriptor: desc), let blit = cmd.makeBlitCommandEncoder() else {
                throw CIBridgeError.badArguments
            }
            blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: Int(off.x), y: Int(off.y), z: 0),
                      sourceSize: MTLSize(width: dst.width, height: dst.height, depth: 1),
                      to: cropped, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            src = cropped
        }
        guard let enc = cmd.makeComputeCommandEncoder() else { throw CIBridgeError.badArguments }
        enc.setComputePipelineState(p)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        try bind(enc)
        let w = p.threadExecutionWidth
        let h = max(1, p.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }
}

/// Per-channel gain (exposure, white-balance coefficients): the `exposureWB` maths on a texture.
final class GainProcessor: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let v = arguments?["scale"] as? CIVector else { throw CIBridgeError.badArguments }
        var s = SIMD4<Float>(Float(v.x), Float(v.y), Float(v.z), 1)
        try BridgeKernels.shared.get().dispatch("gainTex", input: input, output: output) { enc in
            enc.setBytes(&s, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        }
    }
}

/// Tone map and display transform: the `toneDisplay` maths on a texture, output left linear for Core Image.
final class ToneDisplayProcessor: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let contrast = arguments?["contrast"] as? Double else { throw CIBridgeError.badArguments }
        let peak = max((arguments?["peak"] as? Double) ?? 1, 1)
        let kernels = try BridgeKernels.shared.get()
        guard let table = kernels.toneTable(contrast: contrast, peak: peak) else { throw CIBridgeError.badArguments }
        var peakF = Float(peak)
        var p = SIMD4<Float>(Float(ToneMap.grey), Float(ToneMap.minEV), Float(ToneMap.maxEV), Float(ToneMap.tableSize - 1))
        let m = ColorSpaces.rec2020ToSRGB.m
        // columns of the row-major matrix
        let cols = (0..<3).map { c in SIMD4<Float>(Float(m[0][c]), Float(m[1][c]), Float(m[2][c]), 0) }
        try kernels.dispatch("toneDisplayLinearTex", input: input, output: output) { enc in
            enc.setBytes(&p, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            enc.setBytes(cols, length: cols.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
            enc.setBuffer(table, offset: 0, index: 2)
            enc.setBytes(&peakF, length: MemoryLayout<Float>.size, index: 3)
        }
    }
}

/// Any per-pixel card kernel: `function` in `source` reads texture 0, writes texture 1, and takes the
/// uniforms as `constant float *u [[buffer(0)]]`. See `MetalPerPixel` for the buffer twin the checks run.
final class PerPixelProcessor: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let source = arguments?["source"] as? String,
              let function = arguments?["function"] as? String,
              var uniforms = arguments?["uniforms"] as? [Float] else { throw CIBridgeError.badArguments }
        if uniforms.isEmpty { uniforms = [0] }
        try BridgeKernels.shared.get().dispatch(function, source: source, input: input, output: output) { enc in
            enc.setBytes(&uniforms, length: uniforms.count * MemoryLayout<Float>.stride, index: 0)
        }
    }
}

/// The buffer twin of `PerPixelProcessor`, for darkroom-metal-check: `function` in `source` takes
/// `device const float4 *src [[buffer(0)]]`, `device float4 *dst [[buffer(1)]]`,
/// `constant float *u [[buffer(2)]]` and `uint i [[thread_position_in_grid]]`.
public enum MetalPerPixel {
    public static func run(source: String, function: String, pixels: [SIMD4<Float>], uniforms: [Float]) throws -> [SIMD4<Float>] {
        guard !pixels.isEmpty else { return [] }
        let kernels = try BridgeKernels.shared.get()
        let p = try kernels.pipeline(function, source: source)
        let length = pixels.count * MemoryLayout<SIMD4<Float>>.stride
        var u = uniforms.isEmpty ? [Float(0)] : uniforms
        guard let queue = kernels.device.makeCommandQueue(),
              let src = kernels.device.makeBuffer(bytes: pixels, length: length, options: .storageModeShared),
              let dst = kernels.device.makeBuffer(length: length, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
            throw CIBridgeError.badArguments
        }
        enc.setComputePipelineState(p)
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(dst, offset: 0, index: 1)
        enc.setBytes(&u, length: u.count * MemoryLayout<Float>.stride, index: 2)
        enc.dispatchThreads(MTLSize(width: pixels.count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: p.threadExecutionWidth, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let out = dst.contents().bindMemory(to: SIMD4<Float>.self, capacity: pixels.count)
        return Array(UnsafeBufferPointer(start: out, count: pixels.count))
    }
}

/// What the engine calls. Each returns the image unchanged at identity settings, so a default stack
/// never pays for a GPU pass.
public enum CIBridge {
    /// Multiplies RGB by `scale` in the image's working space.
    public static func gain(_ image: CIImage, scale: SIMD3<Double>) throws -> CIImage {
        if scale == SIMD3(1, 1, 1) { return image }
        return try GainProcessor.apply(withExtent: image.extent, inputs: [image],
                                       arguments: ["scale": CIVector(x: scale.x, y: scale.y, z: scale.z)])
    }

    /// Runs a card's per-pixel texture kernel (see `PerPixelProcessor`) over `image` in its working space.
    public static func perPixel(_ image: CIImage, source: String, function: String, uniforms: [Float]) throws -> CIImage {
        try PerPixelProcessor.apply(withExtent: image.extent, inputs: [image],
                                    arguments: ["source": source, "function": function, "uniforms": uniforms])
    }

    /// Scene-linear working-space image in, display-linear sRGB (0...1) out: converts to linear Rec.2020,
    /// runs the ToneMap per channel and the display matrix. Core Image applies the sRGB encode on output.
    /// `peak` is linear with SDR white = 1: above 1 the tone map lifts highlights past SDR white (an HDR rendition;
    /// below its knee it is identical to the SDR one, ToneMap's own rule).
    public static func toneDisplay(_ image: CIImage, contrast: Double, peak: Double = 1) throws -> CIImage {
        guard let rec2020 = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else { throw CIBridgeError.badArguments }
        let scene = image.matchedFromWorkingSpace(to: rec2020) ?? image
        return try ToneDisplayProcessor.apply(withExtent: image.extent, inputs: [scene], arguments: ["contrast": contrast, "peak": peak])
    }
}
