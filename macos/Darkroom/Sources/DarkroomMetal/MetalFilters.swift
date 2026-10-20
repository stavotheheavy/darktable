// Method: the same box mean, guided filter (He, Sun and Tang, ECCV 2010) and à trous B3 smoothing (Starck and
// Murtagh, 1994) as DarkroomCore.Filters, on the GPU inside the Core Image graph.
//
// Spatial kernels read a neighbourhood, so each processor asks Core Image for the output rectangle grown by its reach
// (roi), and the image is clamped to its extent first, which is the oracle's clamped-edge rule. Core Image then
// renders tiles and regions by itself; darkroom-engine-check F-E compares regions against the full frame to prove
// the seams. Every channel is filtered the same way; alpha is carried.

import CoreImage
import Foundation
import DarkroomCore
import Metal

enum FilterKernels {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    // pass 1: along x. src covers the output grown by `reach` on every side; dst is as tall as src, as wide as the output
    kernel void filtersRowTex(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int reach = int(u[0]), taps = int(u[1]), step = int(u[2]);
        float4 sum = 0;
        for (int k = 0; k < taps; k++) {
            int dx = (k - taps / 2) * step;
            sum += u[3 + k] * src.read(uint2(int(gid.x) + off[0].x + reach + dx, int(gid.y) + off[0].y));
        }
        dst.write(sum, gid);
    }

    // pass 2: along y, from pass 1's result to the output
    kernel void filtersColTex(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int reach = int(u[0]), taps = int(u[1]), step = int(u[2]);
        float4 sum = 0;
        for (int k = 0; k < taps; k++) {
            int dy = (k - taps / 2) * step;
            sum += u[3 + k] * src.read(uint2(gid.x, int(gid.y) + reach + dy));
        }
        dst.write(sum, gid);
    }

    // guided filter steps, per pixel, several inputs (textures 0...n-1 in, texture n out)
    kernel void filtersLumaTex(texture2d<float, access::read> p [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                               constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = p.read(uint2(int2(gid) + off[0]));
        float y = dot(c.rgb, float3(0.2126f, 0.7152f, 0.0722f));
        dst.write(float4(y, y, y, c.a), gid);
    }
    kernel void filtersMulTex(texture2d<float, access::read> a [[texture(0)]], texture2d<float, access::read> b [[texture(1)]],
                              texture2d<float, access::write> dst [[texture(2)]],
                              constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 x = a.read(uint2(int2(gid) + off[0])), y = b.read(uint2(int2(gid) + off[1]));
        dst.write(float4(x.rgb * y.rgb, x.a), gid);
    }
    // a = (corrIP - meanI meanP) / (corrI - meanI^2 + eps)
    kernel void filtersCoefATex(texture2d<float, access::read> corrIP [[texture(0)]], texture2d<float, access::read> meanI [[texture(1)]],
                                texture2d<float, access::read> meanP [[texture(2)]], texture2d<float, access::read> corrI [[texture(3)]],
                                texture2d<float, access::write> dst [[texture(4)]],
                                constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float3 mi = meanI.read(uint2(int2(gid) + off[1])).rgb;
        float3 a = (corrIP.read(uint2(int2(gid) + off[0])).rgb - mi * meanP.read(uint2(int2(gid) + off[2])).rgb) / (corrI.read(uint2(int2(gid) + off[3])).rgb - mi * mi + u[0]);
        dst.write(float4(a, 1), gid);
    }
    // b = meanP - a meanI
    kernel void filtersCoefBTex(texture2d<float, access::read> meanP [[texture(0)]], texture2d<float, access::read> a [[texture(1)]],
                                texture2d<float, access::read> meanI [[texture(2)]], texture2d<float, access::write> dst [[texture(3)]],
                                constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        dst.write(float4(meanP.read(uint2(int2(gid) + off[0])).rgb - a.read(uint2(int2(gid) + off[1])).rgb * meanI.read(uint2(int2(gid) + off[2])).rgb, 1), gid);
    }
    // q = meanA I + meanB, alpha from the input
    kernel void filtersOutTex(texture2d<float, access::read> meanA [[texture(0)]], texture2d<float, access::read> i [[texture(1)]],
                              texture2d<float, access::read> meanB [[texture(2)]], texture2d<float, access::read> p [[texture(3)]],
                              texture2d<float, access::write> dst [[texture(4)]],
                              constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        dst.write(float4(meanA.read(uint2(int2(gid) + off[0])).rgb * i.read(uint2(int2(gid) + off[1])).rgb + meanB.read(uint2(int2(gid) + off[2])).rgb, p.read(uint2(int2(gid) + off[3])).a), gid);
    }
    """#
}

/// A separable filter: `taps` weights at spacing `step`, reaching `reach` pixels to each side.
/// Where an input texture's pixel (0, 0) sits relative to the output's, in texture pixels. Core Image may hand a
/// larger texture than asked when one image feeds several consumers. `rowZeroIsTop`: whether a texture's first row is
/// its region's top edge (maxY in Core Image's bottom-left coordinates); darkroom-engine-check F-E4's asymmetric
/// regions decide it.
let rowZeroIsTop = true
func textureOffset(input: CGRect, output: CGRect) -> SIMD2<Int32> {
    let dx = Int32((output.minX - input.minX).rounded())
    let dy = Int32((rowZeroIsTop ? input.maxY - output.maxY : output.minY - input.minY).rounded())
    return SIMD2(dx, dy)
}

final class SeparableProcessor: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        let reach = CGFloat((arguments?["reach"] as? Int) ?? 0)
        return outputRect.insetBy(dx: -reach, dy: -reach)
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let src = input.metalTexture, let dst = output.metalTexture,
              let cmd = output.metalCommandBuffer, let reach = arguments?["reach"] as? Int,
              var u = arguments?["uniforms"] as? [Float] else { throw CIBridgeError.badArguments }
        // the input covers at least the output grown by `reach` (it can be larger when the image is shared)
        let grown = output.region.insetBy(dx: CGFloat(-reach), dy: CGFloat(-reach))
        guard input.region.contains(grown) else {
            throw CIBridgeError.regionMismatch(input: input.region, output: output.region)
        }
        // offset of the grown rectangle inside the input texture; pass 1 starts there, pass 2 reads pass 1 as is
        var off = [textureOffset(input: input.region, output: grown), SIMD2<Int32>(0, 0)]
        let kernels = try BridgeKernels.shared.get()
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: dst.width, height: dst.height + 2 * reach, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let mid = kernels.device.makeTexture(descriptor: desc) else { throw CIBridgeError.badArguments }
        for (name, from, to) in [("filtersRowTex", src, mid), ("filtersColTex", mid, dst)] {
            let p = try kernels.pipeline(name, source: FilterKernels.source)
            guard let enc = cmd.makeComputeCommandEncoder() else { throw CIBridgeError.badArguments }
            enc.setComputePipelineState(p)
            enc.setTexture(from, index: 0)
            enc.setTexture(to, index: 1)
            enc.setBytes(&u, length: u.count * MemoryLayout<Float>.stride, index: 0)
            enc.setBytes(&off, length: off.count * MemoryLayout<SIMD2<Int32>>.stride, index: 1)
            let w = p.threadExecutionWidth, h = max(1, p.maxTotalThreadsPerThreadgroup / w)
            enc.dispatchThreads(MTLSize(width: to.width, height: to.height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
            enc.endEncoding()
        }
    }
}

/// A per-pixel kernel over several same-sized inputs (textures 0...n-1), output texture n.
final class PerPixelManyProcessor: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let inputs, !inputs.isEmpty, let function = arguments?["function"] as? String,
              var u = arguments?["uniforms"] as? [Float], let dst = output.metalTexture, let cmd = output.metalCommandBuffer
        else { throw CIBridgeError.badArguments }
        let kernels = try BridgeKernels.shared.get()
        let p = try kernels.pipeline(function, source: (arguments?["source"] as? String) ?? FilterKernels.source)
        // check every input before an encoder exists: an encoder dropped without endEncoding is a crash
        var textures: [MTLTexture] = [], offsets: [SIMD2<Int32>] = []
        for input in inputs {
            guard let t = input.metalTexture, input.region.contains(output.region) else {
                throw CIBridgeError.regionMismatch(input: input.region, output: output.region)
            }
            textures.append(t)
            offsets.append(textureOffset(input: input.region, output: output.region))
        }
        guard let enc = cmd.makeComputeCommandEncoder() else { throw CIBridgeError.badArguments }
        enc.setComputePipelineState(p)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        enc.setTexture(dst, index: inputs.count)
        if u.isEmpty { u = [0] }
        enc.setBytes(&u, length: u.count * MemoryLayout<Float>.stride, index: 0)
        enc.setBytes(&offsets, length: offsets.count * MemoryLayout<SIMD2<Int32>>.stride, index: 1)
        let w = p.threadExecutionWidth, h = max(1, p.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }
}

extension CIBridge {
    private static func separable(_ image: CIImage, reach: Int, taps: [Float], step: Int) throws -> CIImage {
        let ext = image.extent
        let u: [Float] = [Float(reach), Float(taps.count), Float(step)] + taps
        let out = try SeparableProcessor.apply(withExtent: ext, inputs: [image.clampedToExtent()],
                                               arguments: ["reach": reach, "uniforms": u])
        return out.cropped(to: ext)
    }

    private static func many(_ function: String, _ images: [CIImage], _ uniforms: [Float] = []) throws -> CIImage {
        try PerPixelManyProcessor.apply(withExtent: images[0].extent, inputs: images, arguments: ["function": function, "uniforms": uniforms])
    }

    /// A card's per-pixel kernel over several images of the same extent (an image and its smoothed base, say).
    /// `function` in `source` takes `texture2d<float, access::read>` inputs 0...n-1, the output at texture n,
    /// `constant float *u [[buffer(0)]]` and `constant int2 *off [[buffer(1)]]`, and reads input k at
    /// `uint2(int2(gid) + off[k])`: Core Image can hand a larger texture than the output when an image is shared.
    public static func combine(_ images: [CIImage], source: String, function: String, uniforms: [Float]) throws -> CIImage {
        guard let first = images.first else { throw CIBridgeError.badArguments }
        return try PerPixelManyProcessor.apply(withExtent: first.extent, inputs: images,
                                               arguments: ["function": function, "uniforms": uniforms, "source": source])
    }

    /// DarkroomCore.Filters.boxMean on every channel.
    public static func boxMean(_ image: CIImage, radius r: Int) throws -> CIImage {
        guard r > 0 else { return image }
        return try separable(image, reach: r, taps: [Float](repeating: 1 / Float(2 * r + 1), count: 2 * r + 1), step: 1)
    }

    /// DarkroomCore.Filters.atrousSmooth on every channel.
    public static func atrousSmooth(_ image: CIImage, level: Int) throws -> CIImage {
        let step = 1 << level
        return try separable(image, reach: 2 * step, taps: Filters.b3.map { Float($0) }, step: step)
    }

    /// DarkroomCore.Filters.guided on each colour channel, guided by the image's own luminance (Rec.709 weights).
    public static func guided(_ image: CIImage, radius r: Int, eps: Double) throws -> CIImage {
        let i = try many("filtersLumaTex", [image])
        let meanI = try boxMean(i, radius: r), meanP = try boxMean(image, radius: r)
        let corrI = try boxMean(try many("filtersMulTex", [i, i]), radius: r)
        let corrIP = try boxMean(try many("filtersMulTex", [i, image]), radius: r)
        let a = try many("filtersCoefATex", [corrIP, meanI, meanP, corrI], [Float(eps)])
        let b = try many("filtersCoefBTex", [meanP, a, meanI])
        return try many("filtersOutTex", [try boxMean(a, radius: r), i, try boxMean(b, radius: r), image])
    }
}
