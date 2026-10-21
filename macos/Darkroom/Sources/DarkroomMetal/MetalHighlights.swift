// Method: DarkroomCore.HighlightRebuild and HighlightSources on the GPU (checkpoint A2 and A3 of the highlight rebuild, written from their own
// description). The per-pixel rules are the oracle's; the neighbourhood sums become filters: "within a pixel of a clip" and "strongest edge"
// come from a 3 by 3 box mean and minimum of the brightness plane (the minimum of its negative is the maximum), and the window sums over radii
// 2, 4, 8 and 16 are box means of the chroma and weight planes (packed into one image, see hlPackNbTex), which
// read the nearest edge pixel past the picture's edge exactly as the oracle's windows do.
// Checked against the oracle by darkroom-engine-check E-HR (the oracle's own A2 and A3 pictures, seams, strength 0).
//
// Uniforms: u[0] clip, u[1] strength, u[2] supportMin, u[3] supportFull.

import CoreImage
import DarkroomCore
import Foundation

public enum MetalHighlights {
    public static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    static float hl_ramp(float x, float lo, float hi) {
        float t = clamp((x - lo) / (hi - lo), 0.0f, 1.0f);
        return t * t * (3.0f - 2.0f * t);
    }

    // A pixel's source weight (HighlightSources.weights) from the picture's own 3 by 3 neighbourhood: within a pixel of a clipped one (or
    // clipped itself) gives 0; otherwise a ramp on the brightness, faded by the strongest edge to a neighbour. The picture arrives clamped to
    // its extent, so a window that runs off the edge sees only copies of what is inside it, as the oracle's does.
    static float hl_weight_nb(texture2d<float, access::read> src, uint2 gid, int2 base, constant float *u, thread float3 &centre) {
        float3 p[9];
        float bmin = 1e30f, bmax = -1e30f;
        bool nearClip = false;
        for (int dy = 0; dy < 3; dy++) {
            for (int dx = 0; dx < 3; dx++) {
                float3 q = src.read(uint2(int2(gid) + base + int2(dx, dy))).rgb;
                p[dy * 3 + dx] = q;
                float b = max(q.x, max(q.y, q.z));
                bmin = min(bmin, b); bmax = max(bmax, b);
                if (q.x >= u[0] || q.y >= u[0] || q.z >= u[0]) { nearClip = true; }
            }
        }
        float3 c = p[4];
        centre = c;
        if (nearClip) { return 0.0f; }
        float b = max(c.x, max(c.y, c.z));
        float w = hl_ramp(b / u[0], 0.25f, 0.6f);
        if (w == 0.0f) { return 0.0f; }
        float here = max(b, 1e-6f);
        float edge = max(log2(here / max(bmin, 1e-6f)), log2(max(bmax, 1e-6f) / here));
        w *= 1.0f - hl_ramp(edge, 0.15f, 0.4f);
        float mean = (c.x + c.y + c.z) / 3.0f;
        return mean > 0.0f ? w : 0.0f;
    }

    // the packed plane, one image so a window filter and the kernel after it see the chroma and its weight together (never two look-alike
    // images, which Core Image mixes up): (chroma red times weight, chroma green times weight, weight, 1). The chroma is scaled to channel
    // mean 1, so its three channels times the weight sum to 3 * weight and the blue is recovered after the window mean without storing it;
    // alpha stays 1, because anything else is rescaled or replaced by Core Image between filters.
    kernel void hlPackNbTex(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float3 c;
        float w = hl_weight_nb(src, gid, off[0], u, c);
        float mean = (c.x + c.y + c.z) / 3.0f;
        float3 cw = w > 0.0f ? (c / mean) * w : float3(0.0f);
        dst.write(float4(cw.x, cw.y, w, 1.0f), gid);
    }

    // a plain copy: a per-pixel pass between two filters that both grow their input region, which Core Image schedules correctly where it
    // does not schedule the two filters back to back (see CIBridge.highlightRebuild)
    kernel void hlCopyTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                          constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        dst.write(src.read(uint2(int2(gid) + off[0])), gid);
    }

    // inputs: the picture, then the packed window means at radii 2, 4, 8 and 16 (each one image: chroma red and green times weight, weight, 1).
    // The radius search is the oracle's: the first radius, smallest first, whose support (the window mean of the weight) reaches supportMin
    // gives the mean chroma, scaled to channel mean 1 (the blue recovered as 3 * weight minus red minus green).
    kernel void hlRebuildTex(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::read> win2 [[texture(1)]], texture2d<float, access::read> win4 [[texture(2)]],
                             texture2d<float, access::read> win8 [[texture(3)]], texture2d<float, access::read> win16 [[texture(4)]],
                             texture2d<float, access::write> dst [[texture(5)]],
                             constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 px = src.read(uint2(int2(gid) + off[0]));
        float3 p = px.rgb;
        float clip = u[0];
        bool cx = p.x >= clip, cy = p.y >= clip, cz = p.z >= clip;
        int lost = (cx ? 1 : 0) + (cy ? 1 : 0) + (cz ? 1 : 0);
        if (lost == 0 || u[1] <= 0.0f) { dst.write(px, gid); return; }
        float4 m[4] = { win2.read(uint2(int2(gid) + off[1])), win4.read(uint2(int2(gid) + off[2])),
                        win8.read(uint2(int2(gid) + off[3])), win16.read(uint2(int2(gid) + off[4])) };
        float3 chroma = float3(1.0f);
        float support = 0.0f;
        for (int k = 0; k < 4; k++) {
            if (m[k].z >= u[2] && m[k].z > 0.0f) {
                float3 c = float3(m[k].x, m[k].y, 3.0f * m[k].z - m[k].x - m[k].y) / m[k].z;
                chroma = c / ((c.x + c.y + c.z) / 3.0f);
                support = m[k].z;
                break;
            }
        }
        float f = hl_ramp(support, 0.0f, u[3]);
        float3 outc;
        if (lost == 3) {
            outc = float3(clip) + (chroma * clip - float3(clip)) * f;
        } else {
            bool clipped[3] = { cx, cy, cz };
            float level = 0.0f, eMean = 0.0f;
            int keep = 0;
            for (int c = 0; c < 3; c++) if (!clipped[c]) { level += p[c]; eMean += chroma[c]; keep++; }
            level /= float(keep); eMean /= float(keep);
            outc = p;
            for (int c = 0; c < 3; c++) {
                if (!clipped[c]) { continue; }
                float candidate = eMean > 0.0f ? level * chroma[c] / eMean : clip;
                outc[c] = clip + max(candidate - clip, 0.0f) * f;
            }
        }
        dst.write(float4(mix(p, outc, u[1]), px.a), gid);
    }
    """#
}

extension CIBridge {
    /// DarkroomCore.HighlightRebuild.rebuild on the GPU, blended with the picture by `strength`.
    public static func highlightRebuild(_ image: CIImage, clip: Double, strength: Double) throws -> CIImage {
        guard strength > 0, clip > 0 else { return image }
        let src = MetalHighlights.source
        let u: [Float] = [Float(clip), Float(min(strength, 1)), Float(HighlightRebuild.supportMin), Float(HighlightRebuild.supportFull)]
        let extent = image.extent
        // One packed plane (see hlPackNbTex) from the picture's 3 by 3 neighbourhood. Its box means must reach up to 16 px past the picture's
        // edge, and Core Image hands a clamped (infinite) input only one pixel past a finite extent: a filter that needs more throws a region
        // error and the frame comes out blank. So each window is made from an explicitly padded copy: the plane clamped to its extent and
        // cropped to a larger FINITE rectangle (the nearest edge pixel fills the margin, as the oracle's windows read), shifted to the
        // origin, filtered, shifted back and cropped to the picture. Every region any filter needs then lies inside an extent.
        let pack = try NeighbourhoodProcessor.apply(withExtent: extent, inputs: [image.clampedToExtent()],
                                                    arguments: ["function": "hlPackNbTex", "uniforms": u, "source": src]).cropped(to: extent)
        func window(radius r: Int) throws -> CIImage {
            let ext = extent.insetBy(dx: -CGFloat(r + 1), dy: -CGFloat(r + 1))
            let padded = pack.clampedToExtent().cropped(to: ext)
            let shifted = padded.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            let boxed = try boxMean(shifted, radius: r)
            return boxed.transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY)).cropped(to: extent)
        }
        let windows = try HighlightRebuild.radii.map { try window(radius: $0) }
        return try PerPixelManyProcessor.apply(withExtent: extent, inputs: [image] + windows,
                                               arguments: ["function": "hlRebuildTex", "uniforms": u, "source": src])
    }
}


/// A kernel over a pixel's 3 by 3 neighbourhood of a single input: the input comes clamped to its extent and the kernel reads it at
/// `uint2(int2(gid) + off[0] + (dx, dy))` for dx, dy in 0...2 (the pixel itself is dx = dy = 1).
final class NeighbourhoodProcessor: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        outputRect.insetBy(dx: -1, dy: -1)
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let src = input.metalTexture, let dst = output.metalTexture, let cmd = output.metalCommandBuffer,
              let function = arguments?["function"] as? String, var u = arguments?["uniforms"] as? [Float] else { throw CIBridgeError.badArguments }
        let grown = output.region.insetBy(dx: -1, dy: -1)
        guard input.region.contains(grown) else {
            if ProcessInfo.processInfo.environment["DARKROOM_TRACE_REGIONS"] != nil {
                FileHandle.standardError.write(Data("neighbourhood: input \(input.region) does not cover \(grown) (output \(output.region))\n".utf8))
            }
            throw CIBridgeError.regionMismatch(input: input.region, output: output.region)
        }
        var off = [textureOffset(input: input.region, output: grown)]
        let kernels = try BridgeKernels.shared.get()
        let p = try kernels.pipeline(function, source: (arguments?["source"] as? String) ?? "")
        guard let enc = cmd.makeComputeCommandEncoder() else { throw CIBridgeError.badArguments }
        enc.setComputePipelineState(p)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBytes(&u, length: u.count * MemoryLayout<Float>.stride, index: 0)
        enc.setBytes(&off, length: off.count * MemoryLayout<SIMD2<Int32>>.stride, index: 1)
        let w = p.threadExecutionWidth, h = max(1, p.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }
}
