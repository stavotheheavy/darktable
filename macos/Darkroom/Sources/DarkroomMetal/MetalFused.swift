// Method: kernel fusion of consecutive per-pixel operations (the producer-consumer fusion of Halide, J. Ragan-Kelley et al., "Halide: A
// Language and Compiler for Optimizing Parallelism, Locality, and Recomputation in Image Processing Pipelines", PLDI 2013, applied by hand):
// a run of modules that each map one pixel to one pixel is evaluated in registers, one read and one write of the frame for the whole run
// instead of a full float frame written and read back between every pair.
//
// The functions are the cards' own (`colorbalance_apply`, `mixer_apply`, `tonecurve_apply`, `monochrome_apply`, `levels_apply`, `split_apply`,
// `st_apply`, `invert_apply`, `colisa_apply`, `colorzones_apply`, `satcurve_apply`, `lgg_apply`, `basecurve_apply`, `posterize_apply`, `colorize_apply`, `solarize_apply`, `negadoctor_apply`, `lowlight_apply`), compiled into one library with a driver kernel that walks an op list. Every thread takes the same branches, so the switch costs
// nothing. Checked against the unfused chain by darkroom-engine-check E-FU (random stacks) and by every module's own check, which now run
// through it.
//
// Uniforms: u[0] the op count n; then n pairs (op code, offset of that op's parameters); the parameters follow. An op's parameters are exactly
// the uniforms its card's own kernel takes.

import CoreImage
import DarkroomCore
import Foundation

/// One step of a fused run: which card function, and the uniforms that card's kernel takes.
public struct FusedOp: Sendable, Equatable {
    public enum Code: Int, Sendable { case gain = 0, colorBalance, channelMixer, toneCurve, monochrome, levels, splitToning, sceneTone, invert, colisa, colorZones, satCurve, liftGammaGain, baseCurve, posterize, colorize, solarize, negadoctor, lowLight }
    public let code: Code
    public let params: [Float]
    public init(_ code: Code, _ params: [Float]) { self.code = code; self.params = params }
}

public enum MetalFused {
    /// The most ops one pass takes (the uniforms go through setBytes, which allows 4 KB).
    public static let maxOps = 10

    public static let source: String = {
        var s = MetalColorCommon.source
        for part in [MetalColorBalance.source, MetalChannelMixer.source, MetalToneCurve.source, MetalMonochrome.source,
                     MetalLevels.source, MetalSplitToning.source, MetalSceneTone.source, MetalInvert.source] {
            s += "\n" + part.replacingOccurrences(of: MetalColorCommon.source, with: "") + "\n"
        }
        // a function built on another card's function, so it comes after the loop and carries no kernels of its own
        s += MetalColisa.function
        s += MetalColorZones.function
        s += MetalSatCurve.function
        s += MetalLiftGammaGain.function
        s += MetalBaseCurve.function
        s += MetalPosterize.function
        s += MetalColorize.function
        s += MetalSolarize.function
        s += MetalNegativeFilm.function
        s += MetalLowLight.function
        s += #"""

        kernel void fusedTex(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant float *u [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            float4 c = src.read(gid);
            float3 rgb = c.rgb;
            int n = int(u[0] + 0.5f);
            for (int i = 0; i < n; i++) {
                int code = int(u[1 + 2 * i] + 0.5f);
                constant float *p = u + int(u[2 + 2 * i] + 0.5f);
                switch (code) {
                    case 0: rgb *= float3(p[0], p[1], p[2]); break;
                    case 1: rgb = colorbalance_apply(rgb, p); break;
                    case 2: rgb = mixer_apply(rgb, p); break;
                    case 3: rgb = tonecurve_apply(rgb, p); break;
                    case 4: rgb = monochrome_apply(rgb, p); break;
                    case 5: rgb = levels_apply(rgb, p); break;
                    case 6: rgb = split_apply(rgb, p); break;
                    case 7: rgb = st_apply(rgb, p); break;
                    case 8: rgb = invert_apply(rgb, p); break;
                    case 9: rgb = colisa_apply(rgb, p); break;
                    case 10: rgb = colorzones_apply(rgb, p); break;
                    case 11: rgb = satcurve_apply(rgb, p); break;
                    case 12: rgb = lgg_apply(rgb, p); break;
                    case 13: rgb = basecurve_apply(rgb, p); break;
                    case 14: rgb = posterize_apply(rgb, p); break;
                    case 15: rgb = colorize_apply(rgb, p); break;
                    case 16: rgb = solarize_apply(rgb, p); break;
                    case 17: rgb = negadoctor_apply(rgb, p); break;
                    case 18: rgb = lowlight_apply(rgb, p); break;
                    default: break;
                }
            }
            dst.write(float4(rgb, c.a), gid);
        }

        kernel void fusedBuf(device const float4 *src [[buffer(0)]],
                             device float4 *dst [[buffer(1)]],
                             constant float *u [[buffer(2)]],
                             uint i [[thread_position_in_grid]]) {
            float4 c = src[i];
            float3 rgb = c.rgb;
            int n = int(u[0] + 0.5f);
            for (int k = 0; k < n; k++) {
                int code = int(u[1 + 2 * k] + 0.5f);
                constant float *p = u + int(u[2 + 2 * k] + 0.5f);
                switch (code) {
                    case 0: rgb *= float3(p[0], p[1], p[2]); break;
                    case 1: rgb = colorbalance_apply(rgb, p); break;
                    case 2: rgb = mixer_apply(rgb, p); break;
                    case 3: rgb = tonecurve_apply(rgb, p); break;
                    case 4: rgb = monochrome_apply(rgb, p); break;
                    case 5: rgb = levels_apply(rgb, p); break;
                    case 6: rgb = split_apply(rgb, p); break;
                    case 7: rgb = st_apply(rgb, p); break;
                    case 8: rgb = invert_apply(rgb, p); break;
                    case 9: rgb = colisa_apply(rgb, p); break;
                    case 10: rgb = colorzones_apply(rgb, p); break;
                    case 11: rgb = satcurve_apply(rgb, p); break;
                    case 12: rgb = lgg_apply(rgb, p); break;
                    case 13: rgb = basecurve_apply(rgb, p); break;
                    case 14: rgb = posterize_apply(rgb, p); break;
                    case 15: rgb = colorize_apply(rgb, p); break;
                    case 16: rgb = solarize_apply(rgb, p); break;
                    case 17: rgb = negadoctor_apply(rgb, p); break;
                    case 18: rgb = lowlight_apply(rgb, p); break;
                    default: break;
                }
            }
            dst[i] = float4(rgb, c.a);
        }
        """#
        return s
    }()

    /// The uniforms for a run of ops (at most `maxOps`).
    public static func pack(_ ops: [FusedOp]) -> [Float] {
        var head: [Float] = [Float(ops.count)]
        var body: [Float] = []
        let base = 1 + 2 * ops.count
        for op in ops {
            head += [Float(op.code.rawValue), Float(base + body.count)]
            body += op.params
        }
        return head + body
    }
}

extension CIBridge {
    /// A run of per-pixel ops as one pass over `image`. An empty run is the image itself.
    public static func fused(_ image: CIImage, ops: [FusedOp]) throws -> CIImage {
        guard !ops.isEmpty else { return image }
        // a longer run is two passes: the order is kept
        if ops.count > MetalFused.maxOps {
            return try fused(try fused(image, ops: Array(ops.prefix(MetalFused.maxOps))), ops: Array(ops.dropFirst(MetalFused.maxOps)))
        }
        return try perPixel(image, source: MetalFused.source, function: "fusedTex", uniforms: MetalFused.pack(ops))
    }
}
