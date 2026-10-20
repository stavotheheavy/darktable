// Method: the monochrome card's filter formula, on OkLab (Björn Ottosson, 2020) via MetalColorCommon.
//
// The Metal kernel for `Monochrome`. The CPU computes the filter's direction, so the kernel only needs its
// cosine and sine. Checked against Monochrome.apply by darkroom-metal-check (monochromeBuf) and through
// Core Image by darkroom-engine-check (E-MO).
//
// Uniforms: u[0] intensity, u[1] filter strength, u[2] cos(filter hue), u[3] sin(filter hue).

import Foundation

public enum MetalMonochrome {
    public static let source = MetalColorCommon.source + #"""

static float3 monochrome_apply(float3 rgb, constant float *u) {
    float y = cc_luminance(rgb);
    float3 lab = cc_to_oklab(rgb);
    float c = length(lab.yz);
    float m = 0.0f;
    if (c >= 1e-9f) {
        m = dot(lab.yz, float2(u[2], u[3])) / c * min(c / 0.15f, 1.0f);
    }
    float yb = y * max(1.0f + u[1] * m, 0.0f);
    return rgb + u[0] * (float3(yb) - rgb);
}

kernel void monochromeTex(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant float *u [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(monochrome_apply(c.rgb, u), c.a), gid);
}

kernel void monochromeBuf(device const float4 *src [[buffer(0)]],
                          device float4 *dst [[buffer(1)]],
                          constant float *u [[buffer(2)]],
                          uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(monochrome_apply(c.rgb, u), c.a);
}
"""#
}
