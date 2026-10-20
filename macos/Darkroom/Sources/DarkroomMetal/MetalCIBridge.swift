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
}

/// The pipelines the bridge runs, compiled once from the buffer kernels' own sources plus the texture
/// entry points below.
final class BridgeKernels: @unchecked Sendable {
    static let shared: Result<BridgeKernels, Error> = Result { try BridgeKernels() }

    let device: MTLDevice
    private let library: MTLLibrary
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()
    private var toneTables: [Double: MTLBuffer] = [:]

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
                                     uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(gid);
        float3 toned = float3(toneLookup(c.r, params, table),
                              toneLookup(c.g, params, table),
                              toneLookup(c.b, params, table));
        float3x3 m = float3x3(columns[0].xyz, columns[1].xyz, columns[2].xyz);
        dst.write(float4(clamp(m * toned, 0.0f, 1.0f), c.a), gid);
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

    /// The ToneMap table for one contrast value, uploaded once and reused.
    func toneTable(contrast: Double) -> MTLBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if let b = toneTables[contrast] { return b }
        let table = ToneMap(contrast: contrast).table.map { Float($0) }
        let b = device.makeBuffer(bytes: table, length: table.count * MemoryLayout<Float>.stride, options: .storageModeShared)
        if toneTables.count > 32 { toneTables.removeAll() }
        toneTables[contrast] = b
        return b
    }

    /// Encodes `name` over the output texture with `bind` setting its buffers (textures 0 and 1 are set here).
    func dispatch(_ name: String, input: CIImageProcessorInput, output: CIImageProcessorOutput,
                  bind: (MTLComputeCommandEncoder) throws -> Void) throws {
        let p = try pipeline(name)
        guard let cmd = output.metalCommandBuffer, let src = input.metalTexture, let dst = output.metalTexture,
              let enc = cmd.makeComputeCommandEncoder() else { throw CIBridgeError.badArguments }
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
        let kernels = try BridgeKernels.shared.get()
        guard let table = kernels.toneTable(contrast: contrast) else { throw CIBridgeError.badArguments }
        var p = SIMD4<Float>(Float(ToneMap.grey), Float(ToneMap.minEV), Float(ToneMap.maxEV), Float(ToneMap.tableSize - 1))
        let m = ColorSpaces.rec2020ToSRGB.m
        // columns of the row-major matrix
        let cols = (0..<3).map { c in SIMD4<Float>(Float(m[0][c]), Float(m[1][c]), Float(m[2][c]), 0) }
        try kernels.dispatch("toneDisplayLinearTex", input: input, output: output) { enc in
            enc.setBytes(&p, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            enc.setBytes(cols, length: cols.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
            enc.setBuffer(table, offset: 0, index: 2)
        }
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

    /// Scene-linear working-space image in, display-linear sRGB (0...1) out: converts to linear Rec.2020,
    /// runs the ToneMap per channel and the display matrix. Core Image applies the sRGB encode on output.
    public static func toneDisplay(_ image: CIImage, contrast: Double) throws -> CIImage {
        guard let rec2020 = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else { throw CIBridgeError.badArguments }
        let scene = image.matchedFromWorkingSpace(to: rec2020) ?? image
        return try ToneDisplayProcessor.apply(withExtent: image.extent, inputs: [scene], arguments: ["contrast": contrast])
    }
}
