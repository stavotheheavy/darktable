// Method: a power curve on the sRGB-encoded value (IEC 61966-2-1), the same maths as BaseCurve in DarkroomCore. Uniform: u[0] the gamma.

import DarkroomCore
import Foundation

/// The Metal function for `BaseCurve`. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalBaseCurve {
    public static let function: String = """

static float bc_encode(float v) {
    float x = isnan(v) ? 0.0f : clamp(v, 0.0f, 1.0f);
    return x <= 0.0031308f ? x * 12.92f : 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
}
static float bc_decode(float e) {
    return e <= 0.04045f ? e / 12.92f : pow((e + 0.055f) / 1.055f, 2.4f);
}

static float3 basecurve_apply(float3 rgb, constant float *u) {
    return float3(bc_decode(pow(bc_encode(rgb.x), u[0])), bc_decode(pow(bc_encode(rgb.y), u[0])), bc_decode(pow(bc_encode(rgb.z), u[0])));
}
"""

    public static let source = MetalColorCommon.source + function + #"""

kernel void basecurveTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(basecurve_apply(c.rgb, u), c.a), gid);
}

kernel void basecurveBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(basecurve_apply(c.rgb, u), c.a);
}
"""#
}
