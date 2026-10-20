// Method: OkLab (Björn Ottosson, 2020) for the chroma step; contrast is a power about middle grey on scene luminance; vibrance weights the chroma gain by how dull the colour is (this card's maths, see colorbalance.md).
import Foundation

/// The Metal kernel for `ColorBalance`. Uniforms: `u[0]` contrast, `u[1]` saturation, `u[2]` vibrance.
/// The shared OkLab and luminance helpers come from `MetalColorCommon.source`.
public enum MetalColorBalance {
    public static let source = MetalColorCommon.source + #"""

static float3 colorbalance_apply(float3 rgb, constant float *u) {
    float contrast = u[0], saturation = u[1], vibrance = u[2];
    float y = cc_luminance(rgb);
    if (y > 0.0f) { rgb *= pow(y / 0.18f, contrast); }
    float3 lab = cc_to_oklab(rgb);
    float chroma = length(lab.yz);
    float w = 1.0f - cc_smoothstep(0.0f, 0.2f, chroma);
    float k = max((1.0f + saturation) * (1.0f + vibrance * w), 0.0f);
    lab.yz *= k;
    return cc_from_oklab(lab);
}

kernel void colorbalanceTex(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant float *u [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(colorbalance_apply(c.rgb, u), c.a), gid);
}

kernel void colorbalanceBuf(device const float4 *src [[buffer(0)]],
                            device float4 *dst [[buffer(1)]],
                            constant float *u [[buffer(2)]],
                            uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(colorbalance_apply(c.rgb, u), c.a);
}
"""#
}
