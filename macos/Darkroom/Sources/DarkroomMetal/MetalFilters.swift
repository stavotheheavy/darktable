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


    // Compensated (Kahan-Neumaier) float4 sums for the running-window box mean below: a window slid along 6000 pixels in plain float would drift.
    struct KSum { float4 s; float4 c; };
    static void kadd(thread KSum &a, float4 v) {
        float4 t = a.s + v;
        a.c += select((v - t) + a.s, (a.s - t) + v, abs(a.s) >= abs(v));
        a.s = t;
    }

    // box mean by a running sum, one thread per row (pass 1, along x) or per column (pass 2, along y): constant cost per pixel at any radius.
    // u = reach, n (whole taps each side), f (weight of the two outer taps), norm (2 r + 1). Same indexing and padding as filtersRowTex / filtersColTex.
    kernel void boxRowRunTex(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                             uint line [[thread_position_in_grid]]) {
        if (line >= dst.get_height()) { return; }
        int reach = int(u[0]), n = int(u[1]), W = int(dst.get_width());
        float f = u[2], inv = 1.0f / u[3];
        int y = int(line) + off[0].y, x0 = off[0].x + reach;
        KSum a = { float4(0), float4(0) };
        for (int k = -n; k <= n; k++) { kadd(a, src.read(uint2(x0 + k, y))); }
        for (int x = 0; x < W; x++) {
            float4 r = a.s + a.c;
            if (f > 0.0f) { r += f * (src.read(uint2(x0 + x - n - 1, y)) + src.read(uint2(x0 + x + n + 1, y))); }
            dst.write(r * inv, uint2(x, line));
            kadd(a, src.read(uint2(x0 + x + n + 1, y)));
            kadd(a, -src.read(uint2(x0 + x - n, y)));
        }
    }

    kernel void boxColRunTex(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                             uint col [[thread_position_in_grid]]) {
        if (col >= dst.get_width()) { return; }
        int reach = int(u[0]), n = int(u[1]), H = int(dst.get_height());
        float f = u[2], inv = 1.0f / u[3];
        KSum a = { float4(0), float4(0) };
        for (int k = -n; k <= n; k++) { kadd(a, src.read(uint2(col, reach + k))); }
        for (int y = 0; y < H; y++) {
            float4 r = a.s + a.c;
            if (f > 0.0f) { r += f * (src.read(uint2(col, reach + y - n - 1)) + src.read(uint2(col, reach + y + n + 1))); }
            dst.write(r * inv, uint2(col, y));
            kadd(a, src.read(uint2(col, reach + y + n + 1)));
            kadd(a, -src.read(uint2(col, reach + y - n)));
        }
    }

    // the minimum over the same window shape (u[0] = reach); the dark channel's patch minimum
    kernel void filtersMinRowTex(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int reach = int(u[0]);
        float4 m = src.read(uint2(int(gid.x) + off[0].x + reach - reach, int(gid.y) + off[0].y));
        for (int dx = -reach; dx <= reach; dx++) {
            m = min(m, src.read(uint2(int(gid.x) + off[0].x + reach + dx, int(gid.y) + off[0].y)));
        }
        dst.write(m, gid);
    }
    kernel void filtersMinColTex(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int reach = int(u[0]);
        float4 m = src.read(uint2(gid.x, int(gid.y) + reach));
        for (int dy = -reach; dy <= reach; dy++) {
            m = min(m, src.read(uint2(gid.x, int(gid.y) + reach + dy)));
        }
        dst.write(m, gid);
    }

    // guided filter steps, per pixel, several inputs (textures 0...n-1 in, texture n out)
    kernel void filtersLumaTex(texture2d<float, access::read> p [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                               constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = p.read(uint2(int2(gid) + off[0]));
        float y = dot(c.rgb, \#(MetalColorCommon.lumaVector));
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
            if ProcessInfo.processInfo.environment["DARKROOM_TRACE_REGIONS"] != nil {
                FileHandle.standardError.write(Data("separable reach \(reach): input \(input.region) does not cover \(grown) (output \(output.region))\n".utf8))
            }
            throw CIBridgeError.regionMismatch(input: input.region, output: output.region)
        }
        // offset of the grown rectangle inside the input texture; pass 1 starts there, pass 2 reads pass 1 as is
        var off = [textureOffset(input: input.region, output: grown), SIMD2<Int32>(0, 0)]
        let kernels = try BridgeKernels.shared.get()
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: dst.width, height: dst.height + 2 * reach, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let mid = kernels.device.makeTexture(descriptor: desc) else { throw CIBridgeError.badArguments }
        let names = (arguments?["kernels"] as? [String]) ?? ["filtersRowTex", "filtersColTex"]
        guard names.count == 2 else { throw CIBridgeError.badArguments }
        let lines = (arguments?["lines"] as? Bool) ?? false
        for (name, from, to) in [(names[0], src, mid), (names[1], mid, dst)] {
            let p = try kernels.pipeline(name, source: FilterKernels.source)
            guard let enc = cmd.makeComputeCommandEncoder() else { throw CIBridgeError.badArguments }
            enc.setComputePipelineState(p)
            enc.setTexture(from, index: 0)
            enc.setTexture(to, index: 1)
            enc.setBytes(&u, length: u.count * MemoryLayout<Float>.stride, index: 0)
            enc.setBytes(&off, length: off.count * MemoryLayout<SIMD2<Int32>>.stride, index: 1)
            if lines {
                // one thread per row (pass 1: `to` is the grown-height texture) or per column (pass 2)
                let count = from === src ? to.height : to.width
                enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(count, 64), height: 1, depth: 1))
            } else {
                let w = p.threadExecutionWidth, h = max(1, p.maxTotalThreadsPerThreadgroup / w)
                enc.dispatchThreads(MTLSize(width: to.width, height: to.height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
            }
            enc.endEncoding()
        }
    }
}

/// A per-pixel kernel over several same-sized inputs (textures 0...n-1), output texture n.
final class PerPixelManyProcessor: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    /// A gather kernel (a mosaic) names how far it reads past its output as `reach`; the others read only their own pixel.
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        let reach = CGFloat((arguments?["reach"] as? Int) ?? 0)
        let grown = outputRect.insetBy(dx: -reach, dy: -reach)
        // a kernel that clamps its own read positions into the frame (`clampToFrame`) never needs a pixel from outside it, so it asks for none: Core Image
        // supplies only a thin ring past the frame to a processor whose input is another processor's output, and a gather that asked for more got black
        if arguments?["clampToFrame"] as? Bool == true, let e = arguments?["extent"] as? [Double], e.count == 4 {
            let inFrame = grown.intersection(CGRect(x: e[0], y: e[1], width: e[2], height: e[3]))
            return inFrame.isNull ? outputRect : inFrame.union(outputRect)
        }
        return grown
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let inputs, !inputs.isEmpty, let function = arguments?["function"] as? String,
              var u = arguments?["uniforms"] as? [Float], let dst = output.metalTexture, let cmd = output.metalCommandBuffer
        else { throw CIBridgeError.badArguments }
        let kernels = try BridgeKernels.shared.get()
        let p = try kernels.pipeline(function, source: (arguments?["source"] as? String) ?? FilterKernels.source)
        if ProcessInfo.processInfo.environment["DARKROOM_TRACE_REGIONS"] != nil {
            FileHandle.standardError.write(Data("many \(function): output \(output.region) inputs \(inputs.map { "\($0.region)" })\n".utf8))
        }
        // check every input before an encoder exists: an encoder dropped without endEncoding is a crash
        var textures: [MTLTexture] = [], offsets: [SIMD2<Int32>] = []
        for input in inputs {
            guard let t = input.metalTexture, input.region.contains(output.region) else {
                if ProcessInfo.processInfo.environment["DARKROOM_TRACE_REGIONS"] != nil {
                    FileHandle.standardError.write(Data("many \(function): input \(input.region) does not cover output \(output.region)\n".utf8))
                }
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
        // where this output sits in the whole image, top-left origin: (x0, y0, width, height). Kernels that need
        // absolute coordinates (masks) read it at buffer(2); others ignore it.
        var geom = SIMD4<Float>(0, 0, 0, 0)
        if let e = arguments?["extent"] as? [Double], e.count == 4 {
            geom = SIMD4(Float(output.region.minX - e[0]), Float(e[1] + e[3] - output.region.maxY), Float(e[2]), Float(e[3]))
        }
        enc.setBytes(&geom, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        let w = p.threadExecutionWidth, h = max(1, p.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }
}

extension CIBridge {
    private static func separable(_ image: CIImage, reach: Int, taps: [Float], step: Int,
                                  kernels: [String] = ["filtersRowTex", "filtersColTex"]) throws -> CIImage {
        let ext = image.extent
        let u: [Float] = [Float(reach), Float(taps.count), Float(step)] + taps
        let out = try SeparableProcessor.apply(withExtent: ext, inputs: [image.clampedToExtent()],
                                               arguments: ["reach": reach, "uniforms": u, "kernels": kernels])
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
        let e = first.extent
        return try PerPixelManyProcessor.apply(withExtent: e, inputs: images,
                                               arguments: ["function": function, "uniforms": uniforms, "source": source,
                                                           "extent": [Double(e.minX), Double(e.minY), Double(e.width), Double(e.height)]])
    }

    /// DarkroomCore.Filters.minFilter on every channel (the window shrinks at the border, as the oracle's does).
    public static func minFilter(_ image: CIImage, radius r: Int) throws -> CIImage {
        guard r > 0 else { return image }
        return try separable(image, reach: r, taps: [], step: 1, kernels: ["filtersMinRowTex", "filtersMinColTex"])
    }

    /// DarkroomCore.Filters.boxMean on every channel.
    public static func boxMean(_ image: CIImage, radius r: Int) throws -> CIImage {
        guard r > 0 else { return image }
        if r >= runningRadius { return try boxRunning(image, reach: r, n: r, f: 0, norm: Double(2 * r + 1)) }
        return try separable(image, reach: r, taps: [Float](repeating: 1 / Float(2 * r + 1), count: 2 * r + 1), step: 1)
    }

    /// From this radius a box mean slides a running sum along each line (constant cost per pixel); below it the tap kernels read the few taps directly.
    private static let runningRadius = 3

    private static func boxRunning(_ image: CIImage, reach: Int, n: Int, f: Double, norm: Double) throws -> CIImage {
        let ext = image.extent
        let u: [Float] = [Float(reach), Float(n), Float(f), Float(norm)]
        let out = try SeparableProcessor.apply(withExtent: ext, inputs: [image.clampedToExtent()],
                                               arguments: ["reach": reach, "uniforms": u, "kernels": ["boxRowRunTex", "boxColRunTex"], "lines": true])
        return out.cropped(to: ext)
    }

    /// DarkroomCore.Filters.boxMean at a fractional radius r = n + f: the 2n + 1 whole taps plus the two outer taps weighted f, over 2r + 1.
    public static func boxMean(_ image: CIImage, radius r: Double) throws -> CIImage {
        guard r > 0 else { return image }
        let n = Int(r.rounded(.down)), f = r - Double(n)
        guard f > 1e-12 else { return try boxMean(image, radius: n) }
        let reach = n + 1, norm = 2 * r + 1
        if r >= Double(runningRadius) { return try boxRunning(image, reach: reach, n: n, f: f, norm: norm) }
        let taps: [Float] = (-reach...reach).map { k in Float((abs(k) <= n ? 1 : f) / norm) }
        return try separable(image, reach: reach, taps: taps, step: 1)
    }

    /// DarkroomCore.Filters.atrousSmooth on every channel.
    public static func atrousSmooth(_ image: CIImage, level: Int) throws -> CIImage {
        let step = 1 << level
        return try separable(image, reach: 2 * step, taps: Filters.b3.map { Float($0) }, step: step)
    }

    /// DarkroomCore.Filters.guided on each colour channel, guided by the image's own luminance (Rec.709 weights).
    public static func guided(_ image: CIImage, radius r: Int, eps: Double) throws -> CIImage {
        try guided(image, guide: image, radius: r, eps: eps)
    }

    public static func guided(_ image: CIImage, radius r: Double, eps: Double) throws -> CIImage {
        try guided(image, guide: image, radius: r, eps: eps)
    }

    /// DarkroomCore.Filters.guided on each colour channel of `image`, guided by the luminance of `guide`
    /// (same extent), for refining a mask against the photo it was cut from.
    public static func guided(_ image: CIImage, guide: CIImage, radius r: Int, eps: Double) throws -> CIImage {
        try guided(image, guide: guide, radius: Double(r), eps: eps)
    }

    /// The same at a fractional radius (the fractional box mean); a whole radius is the integer filter exactly.
    public static func guided(_ image: CIImage, guide: CIImage, radius r: Double, eps: Double) throws -> CIImage {
        let i = try many("filtersLumaTex", [guide])
        let meanI = try boxMean(i, radius: r), meanP = try boxMean(image, radius: r)
        let corrI = try boxMean(try many("filtersMulTex", [i, i]), radius: r)
        let corrIP = try boxMean(try many("filtersMulTex", [i, image]), radius: r)
        let a = try many("filtersCoefATex", [corrIP, meanI, meanP, corrI], [Float(eps)])
        let b = try many("filtersCoefBTex", [meanP, a, meanI])
        return try many("filtersOutTex", [try boxMean(a, radius: r), i, try boxMean(b, radius: r), image])
    }
}
