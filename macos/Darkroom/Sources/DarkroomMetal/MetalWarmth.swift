// Method: a warm / cool and magenta / green look in OkLab, the same maths as Warmth in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `Warmth`. Uniforms: u[0] the warmth, u[1] the tint. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalWarmth {
    public static let function: String = {
        func f(_ x: Double) -> String { String(format: "%.9ff", x) }
        return """

        static float3 warmth_apply(float3 rgb, constant float *u) {
            float3 lab = cc_to_oklab(rgb);
            float w = cc_smoothstep(0.0f, 0.1f, lab.x);
            lab.y += w * (\(f(Warmth.warmthA)) * u[0] + \(f(Warmth.tintA)) * u[1]);
            lab.z += w * \(f(Warmth.warmthB)) * u[0];
            return cc_from_oklab(lab);
        }
        """
    }()

    public static let source = MetalColorCommon.source + function + #"""

kernel void warmthTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(warmth_apply(c.rgb, u), c.a), gid);
}

kernel void warmthBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(warmth_apply(c.rgb, u), c.a);
}
"""#
}
