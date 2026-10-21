// Method: solarisation on the sRGB-encoded value, the same maths as Solarize in DarkroomCore. Uniforms: u[0] the threshold, u[1] the strength. Calls bc_encode and bc_decode, so a library that holds it also holds MetalBaseCurve.function.

import DarkroomCore
import Foundation

/// The Metal function for `Solarize`. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalSolarize {
    public static let function: String = """

static float sol_channel(float v, float t, float s) {
    float e = bc_encode(v);
    float folded = e > t ? 2.0f * t - e : e;
    return bc_decode(clamp(e + s * (folded - e), 0.0f, 1.0f));
}

static float3 solarize_apply(float3 rgb, constant float *u) {
    return float3(sol_channel(rgb.x, u[0], u[1]), sol_channel(rgb.y, u[0], u[1]), sol_channel(rgb.z, u[0], u[1]));
}
"""

    public static let source = MetalColorCommon.source + MetalBaseCurve.function + function + #"""

kernel void solarizeTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(solarize_apply(c.rgb, u), c.a), gid);
}

kernel void solarizeBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(solarize_apply(c.rgb, u), c.a);
}
"""#
}
