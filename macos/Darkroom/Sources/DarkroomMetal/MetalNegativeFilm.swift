// Method: the inversion of a scanned negative from its density, the same maths as NegativeFilm in DarkroomCore. Uniforms: u[0...2] the film base (per channel), u[3] the exponent, u[4] the exposure gain, u[5] the black offset.

import DarkroomCore
import Foundation

/// The Metal function for `NegativeFilm`. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalNegativeFilm {
    public static let function: String = """

static float3 negadoctor_apply(float3 rgb, constant float *u) {
    float3 dmin = float3(u[0], u[1], u[2]);
    float3 t = max(select(rgb, float3(0.0f), isnan(rgb)), float3(1e-4f));
    return max(u[4] * pow(dmin / t, float3(u[3])) - u[5], float3(0.0f));
}
"""

    public static let source = MetalColorCommon.source + function + #"""

kernel void negadoctorTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(negadoctor_apply(c.rgb, u), c.a), gid);
}

kernel void negadoctorBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(negadoctor_apply(c.rgb, u), c.a);
}
"""#
}
