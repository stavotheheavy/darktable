// Method: quantisation of the sRGB-encoded value (IEC 61966-2-1), the same maths as Posterize in DarkroomCore. Uniform: u[0] the step count, levels - 1.

import DarkroomCore
import Foundation

/// The Metal function for `Posterize`. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalPosterize {
    public static let function: String = """

static float3 posterize_apply(float3 rgb, constant float *u) {
    float n = u[0];
    return float3(bc_decode(round(bc_encode(rgb.x) * n) / n), bc_decode(round(bc_encode(rgb.y) * n) / n), bc_decode(round(bc_encode(rgb.z) * n) / n));
}
"""

    /// Calls bc_encode and bc_decode, so the standalone library holds MetalBaseCurve.function too (the fused library already has it).
    public static let source = MetalColorCommon.source + MetalBaseCurve.function + function + #"""

kernel void posterizeTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(posterize_apply(c.rgb, u), c.a), gid);
}

kernel void posterizeBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(posterize_apply(c.rgb, u), c.a);
}
"""#
}
