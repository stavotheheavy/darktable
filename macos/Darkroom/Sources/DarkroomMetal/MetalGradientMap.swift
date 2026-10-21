// Method: a three-stop OkLab gradient map, the same maths as GradientMap in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `GradientMap`. Uniforms: u[0] the strength, u[1...6] the shadows, midtones and highlights stops (a, b). A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalGradientMap {
    public static let function: String = {
        func f(_ x: Double) -> String { String(format: "%.9ff", x) }
        return """

        static float3 gradientmap_apply(float3 rgb, constant float *u) {
            float3 lab = cc_to_oklab(rgb);
            float l = clamp(isnan(lab.x) ? 0.0f : lab.x, 0.0f, 1.0f);
            float2 s0 = float2(u[1], u[2]), s1 = float2(u[3], u[4]), s2 = float2(u[5], u[6]);
            float2 target = l < 0.5f ? s0 + (s1 - s0) * cc_smoothstep(0.0f, 0.5f, l) : s1 + (s2 - s1) * cc_smoothstep(0.5f, 1.0f, l);
            lab.y += (target.x - lab.y) * u[0];
            lab.z += (target.y - lab.z) * u[0];
            return cc_from_oklab(lab);
        }
        """
    }()

    public static let source = MetalColorCommon.source + function + #"""

kernel void gradientmapTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(gradientmap_apply(c.rgb, u), c.a), gid);
}

kernel void gradientmapBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(gradientmap_apply(c.rgb, u), c.a);
}
"""#
}
