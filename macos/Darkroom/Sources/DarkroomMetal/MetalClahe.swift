// Method: the GPU twin of DarkroomCore.Clahe (Zuiderveld, Graphics Gems IV, 1994): a threadgroup per tile builds that tile's histogram in threadgroup memory with atomics, clips and
// redistributes it and writes the 256-entry mapping; a second pass maps every pixel by bilinear interpolation of the four nearest tiles' mappings. One processor does both, because the
// mappings need the whole frame: its input region is the whole frame whatever part of the output is asked for, so a tiled render gets the same mappings as a full one.

import CoreImage
import DarkroomCore
import Foundation
import Metal

final class ClaheProcessor: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard let e = arguments?["extent"] as? [Double], e.count == 4 else { return outputRect }
        return CGRect(x: e[0], y: e[1], width: e[2], height: e[3])
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let src = input.metalTexture, let dst = output.metalTexture, let cmd = output.metalCommandBuffer,
              let source = arguments?["source"] as? String, var u = arguments?["uniforms"] as? [Float], let e = arguments?["extent"] as? [Double], e.count == 4
        else { throw CIBridgeError.badArguments }
        let frame = CGRect(x: e[0], y: e[1], width: e[2], height: e[3])
        guard input.region.contains(frame) else { throw CIBridgeError.regionMismatch(input: input.region, output: frame) }
        let kernels = try BridgeKernels.shared.get()
        let tilesX = Int(u[0].rounded()), tilesY = Int(u[1].rounded())
        guard let lut = kernels.device.makeBuffer(length: tilesX * tilesY * Clahe.bins * MemoryLayout<Float>.stride, options: .storageModePrivate) else { throw CIBridgeError.badArguments }
        // texel (0, 0) of the frame inside the input texture, and the output tile's corner in the frame (top-left origin)
        let off = textureOffset(input: input.region, output: frame)
        var frameInfo: [Float] = u + [Float(off.x), Float(off.y)]
        var geom = SIMD4<Float>(Float(output.region.minX - frame.minX), Float(frame.maxY - output.region.maxY), Float(frame.width), Float(frame.height))
        let histogram = try kernels.pipeline("claheLutKernel", source: source), apply = try kernels.pipeline("claheApplyKernel", source: source)
        guard let enc1 = cmd.makeComputeCommandEncoder() else { throw CIBridgeError.badArguments }
        enc1.setComputePipelineState(histogram)
        enc1.setTexture(src, index: 0)
        enc1.setBuffer(lut, offset: 0, index: 0)
        enc1.setBytes(&frameInfo, length: frameInfo.count * MemoryLayout<Float>.stride, index: 1)
        enc1.dispatchThreadgroups(MTLSize(width: tilesX * tilesY, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: Clahe.bins, height: 1, depth: 1))
        enc1.endEncoding()
        guard let enc2 = cmd.makeComputeCommandEncoder() else { throw CIBridgeError.badArguments }
        enc2.setComputePipelineState(apply)
        enc2.setTexture(src, index: 0)
        enc2.setTexture(dst, index: 1)
        enc2.setBuffer(lut, offset: 0, index: 0)
        enc2.setBytes(&frameInfo, length: frameInfo.count * MemoryLayout<Float>.stride, index: 1)
        enc2.setBytes(&geom, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        let w = apply.threadExecutionWidth, h = max(1, apply.maxTotalThreadsPerThreadgroup / w)
        enc2.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc2.endEncoding()
    }
}

extension CIBridge {
    private static let claheSource = MetalColorCommon.source + MetalBaseCurve.function + #"""

    // u: [0] tiles x, [1] tiles y, [2] clip, [3] frame width, [4] frame height, [5] amount, [6], [7] the input texel of frame pixel (0, 0)
    static float cl_enc(float3 v, thread float &y) {
        y = cc_luminance(v);
        return isnan(y) ? 0.0f : bc_encode(clamp(y, 0.0f, 1.0f));
    }

    kernel void claheLutKernel(texture2d<float, access::read> src [[texture(0)]], device float *lut [[buffer(0)]], constant float *u [[buffer(1)]],
                               uint tile [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) {
        threadgroup atomic_uint hist[256];
        atomic_store_explicit(&hist[tid], 0u, memory_order_relaxed);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        int tilesX = int(u[0] + 0.5f), tilesY = int(u[1] + 0.5f), W = int(u[3] + 0.5f), H = int(u[4] + 0.5f);
        int2 off = int2(int(u[6]), int(u[7]));
        int tx = int(tile) % tilesX, ty = int(tile) / tilesX;
        int x0 = (tx * W + tilesX - 1) / tilesX, x1 = ((tx + 1) * W + tilesX - 1) / tilesX;
        int y0 = (ty * H + tilesY - 1) / tilesY, y1 = ((ty + 1) * H + tilesY - 1) / tilesY;
        int tw = x1 - x0, th = y1 - y0, n = tw * th;
        for (int i = int(tid); i < n; i += 256) {
            int x = x0 + i % tw, y = y0 + i / tw;
            float lum;
            float e = cl_enc(src.read(uint2(int2(x, y) + off)).rgb, lum);
            int bin = min(255, int(floor(e * 256.0f)));
            atomic_fetch_add_explicit(&hist[bin], 1u, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tid == 0) {
            float total = float(n);
            if (n <= 0) {
                for (int i = 0; i < 256; i++) { lut[tile * 256 + i] = (float(i) + 1.0f) / 256.0f; }
                return;
            }
            float limit = max(1.0f, u[2] * total / 256.0f);
            float excess = 0.0f;
            for (int i = 0; i < 256; i++) { excess += max(float(atomic_load_explicit(&hist[i], memory_order_relaxed)) - limit, 0.0f); }
            float add = excess / 256.0f, cum = 0.0f;
            for (int i = 0; i < 256; i++) {
                cum += min(float(atomic_load_explicit(&hist[i], memory_order_relaxed)), limit) + add;
                lut[tile * 256 + i] = cum / total;
            }
        }
    }

    kernel void claheApplyKernel(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                 device const float *lut [[buffer(0)]], constant float *u [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int tilesX = int(u[0] + 0.5f), tilesY = int(u[1] + 0.5f);
        float W = u[3], H = u[4];
        int ax = int(geom[0].x + 0.5f) + int(gid.x), ay = int(geom[0].y + 0.5f) + int(gid.y);
        float4 c = src.read(uint2(int2(ax, ay) + int2(int(u[6]), int(u[7]))));
        float lum;
        float e = cl_enc(c.rgb, lum);
        if (!(lum > 1e-6f) || !(lum <= 1.0f)) { dst.write(c, gid); return; }
        int bin = min(255, int(floor(e * 256.0f)));
        float tw = W / float(tilesX), th = H / float(tilesY);
        float fx = (float(ax) + 0.5f) / tw - 0.5f, fy = (float(ay) + 0.5f) / th - 0.5f;
        int i0 = int(floor(fx)), j0 = int(floor(fy));
        float wx = fx - float(i0), wy = fy - float(j0);
        int a0 = clamp(i0, 0, tilesX - 1), a1 = clamp(i0 + 1, 0, tilesX - 1), b0 = clamp(j0, 0, tilesY - 1), b1 = clamp(j0 + 1, 0, tilesY - 1);
        float v = (lut[(b0 * tilesX + a0) * 256 + bin] * (1.0f - wx) + lut[(b0 * tilesX + a1) * 256 + bin] * wx) * (1.0f - wy)
                + (lut[(b1 * tilesX + a0) * 256 + bin] * (1.0f - wx) + lut[(b1 * tilesX + a1) * 256 + bin] * wx) * wy;
        float gain = bc_decode(v) / lum;
        dst.write(float4(c.rgb * (1.0f + u[5] * (gain - 1.0f)), c.a), gid);
    }
    """#

    /// DarkroomCore.Clahe.apply on the GPU.
    public static func clahe(_ image: CIImage, tiles: Int, clip: Double, amount: Double) throws -> CIImage {
        guard amount != 0 else { return image }
        let ext = image.extent
        let g = Clahe.grid(tiles: tiles, width: Int(ext.width.rounded()), height: Int(ext.height.rounded()))
        return try ClaheProcessor.apply(withExtent: ext, inputs: [image],
                                        arguments: ["source": claheSource, "extent": [Double(ext.minX), Double(ext.minY), Double(ext.width), Double(ext.height)],
                                                    "uniforms": [Float(g.x), Float(g.y), Float(clip), Float(ext.width), Float(ext.height), Float(amount)]])
    }
}
