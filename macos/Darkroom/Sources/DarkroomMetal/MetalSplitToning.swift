// Method: OkLab (Björn Ottosson, "A perceptual color space for image processing", 2020); the same hue and chroma offset and smoothstep pivot as SplitToning in DarkroomCore, from the splittoning card
import Foundation

/// The Metal kernel for `SplitToning`. Uniforms: `u[0]` the pivot p, `u[1]` and `u[2]` the shadows chroma offset
/// (a, b), `u[3]` and `u[4]` the highlights chroma offset (a, b). The CPU side computes them before the call.
public enum MetalSplitToning {
    public static let source = MetalColorCommon.source + #"""

static float3 split_apply(float3 rgb, constant float *u) {
    float3 lab = cc_to_oklab(rgb);
    float wh = cc_smoothstep(u[0] - 0.2f, u[0] + 0.2f, lab.x);
    float ws = 1.0f - wh;
    lab.y += ws * u[1] + wh * u[3];
    lab.z += ws * u[2] + wh * u[4];
    return cc_from_oklab(lab);
}

kernel void splitTex(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant float *u [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(split_apply(c.rgb, u), c.a), gid);
}

kernel void splitBuf(device const float4 *src [[buffer(0)]],
                     device float4 *dst [[buffer(1)]],
                     constant float *u [[buffer(2)]],
                     uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(split_apply(c.rgb, u), c.a);
}
"""#
}
