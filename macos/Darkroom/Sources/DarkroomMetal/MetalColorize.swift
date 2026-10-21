// Method: OkLab chroma mixed toward a fixed tint, the same maths as Colorize in DarkroomCore. Uniforms: u[0] the strength, u[1] and u[2] the tint (a, b), computed by Colorize.tint.

import DarkroomCore
import Foundation

/// The Metal function for `Colorize`. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalColorize {
    public static let function: String = """

static float3 colorize_apply(float3 rgb, constant float *u) {
    float3 lab = cc_to_oklab(rgb);
    lab.y += (u[1] - lab.y) * u[0];
    lab.z += (u[2] - lab.z) * u[0];
    return cc_from_oklab(lab);
}
"""

    public static let source = MetalColorCommon.source + function + #"""

kernel void colorizeTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(colorize_apply(c.rgb, u), c.a), gid);
}

kernel void colorizeBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(colorize_apply(c.rgb, u), c.a);
}
"""#
}
