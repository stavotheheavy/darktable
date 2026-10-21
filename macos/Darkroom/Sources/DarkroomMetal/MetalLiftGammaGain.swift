// Method: the ASC CDL transfer function about scene white, as LiftGammaGain in DarkroomCore; the CPU computes the nine terms, the kernel only applies them.

import DarkroomCore
import Foundation

/// The Metal function for `LiftGammaGain`. Uniforms: `u[0...2]` the slope, `u[3...5]` the offset, `u[6...8]` the power (per channel).
/// A function only, no kernels: it is compiled into the fused pass.
public enum MetalLiftGammaGain {
    public static let function: String = {
        let pivot = String(format: "%.9ff", LiftGammaGain.pivot)
        return """

        static float3 lgg_apply(float3 rgb, constant float *u) {
            float3 slope = float3(u[0], u[1], u[2]);
            float3 offset = float3(u[3], u[4], u[5]);
            float3 power = float3(u[6], u[7], u[8]);
            float3 x = max(rgb * slope + offset, float3(0.0f));
            return \(pivot) * pow(x / \(pivot), power);
        }
        """
    }()

    /// Standalone kernels for darkroom-metal-check (the fused pass uses `function` alone).
    public static let source = MetalColorCommon.source + function + #"""

kernel void lggTex(texture2d<float, access::read> src [[texture(0)]],
                   texture2d<float, access::write> dst [[texture(1)]],
                   constant float *u [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(lgg_apply(c.rgb, u), c.a), gid);
}

kernel void lggBuf(device const float4 *src [[buffer(0)]],
                   device float4 *dst [[buffer(1)]],
                   constant float *u [[buffer(2)]],
                   uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(lgg_apply(c.rgb, u), c.a);
}
"""#
}
