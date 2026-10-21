// Method: the OkLab LCh hue harmonisation of ColorHarmony in DarkroomCore: the pull toward the nearest scheme hue, continuous round the wheel.

import DarkroomCore
import Foundation

/// The Metal function for `ColorHarmony`. Uniforms: u[0] the number of scheme hues (2...4), u[1...4] the hues in radians, u[5] the half gap, u[6] the amount.
/// A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalColorHarmony {
    public static let function = #"""

static float3 colorharmony_apply(float3 rgb, constant float *u) {
    float3 lab = cc_to_oklab(rgb);
    float c = length(lab.yz);
    if (!(c > 0.0f) || !isfinite(c)) { return rgb; }
    float h = atan2(lab.z, lab.y);
    int n = int(u[0] + 0.5f);
    float best = 0.0f;
    bool have = false;
    for (int i = 0; i < n; i++) {
        float d = atan2(sin(u[1 + i] - h), cos(u[1 + i] - h));
        if (!have || fabs(d) < fabs(best)) { best = d; have = true; }
    }
    float pull = u[6] * cc_smoothstep(0.0f, 0.04f, c) * (1.0f - cc_smoothstep(0.0f, u[5], fabs(best)));
    float h2 = h + best * pull;
    return cc_from_oklab(float3(lab.x, c * cos(h2), c * sin(h2)));
}
"""#

    public static let source = MetalColorCommon.source + function + #"""

kernel void colorharmonyTex(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant float *u [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(colorharmony_apply(c.rgb, u), c.a), gid);
}

kernel void colorharmonyBuf(device const float4 *src [[buffer(0)]],
                            device float4 *dst [[buffer(1)]],
                            constant float *u [[buffer(2)]],
                            uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(colorharmony_apply(c.rgb, u), c.a);
}
"""#
}
