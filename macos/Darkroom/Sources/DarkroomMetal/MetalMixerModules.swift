// Method: the per-pixel functions of DarkroomCore's BWMixer (a weighted grey from the scene-linear channels) and SelectiveColor (ink-style adjustments by colour family on the encoded
// value), for the fused pass.

import DarkroomCore
import Foundation

public enum MetalBWMixer {
    /// Uniforms: u[0...2] the red, green and blue weights, u[3] the amount.
    public static let function = #"""

static float3 bwmixer_apply(float3 rgb, constant float *u) {
    float y = dot(float3(u[0], u[1], u[2]), rgb);
    return rgb + u[3] * (float3(y) - rgb);
}
"""#

    public static let source = MetalColorCommon.source + function + #"""

kernel void bwmixerBuf(device const float4 *src [[buffer(0)]], device float4 *dst [[buffer(1)]], constant float *u [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(bwmixer_apply(c.rgb, u), c.a);
}
"""#
}

public enum MetalSelectiveColor {
    /// Uniforms: u[0...23] the families (reds, yellows, greens, cyans, blues, magentas) x (c, m, y, k). Calls bc_encode/bc_decode (MetalBaseCurve.function).
    public static let function = #"""

static float3 selectivecolor_apply(float3 rgb, constant float *u) {
    float3 e = float3(bc_encode(rgb.x), bc_encode(rgb.y), bc_encode(rgb.z));
    float mx = max(e.x, max(e.y, e.z)), mn = min(e.x, min(e.y, e.z)), d = mx - mn;
    float t = cc_smoothstep(0.0f, 0.1f, d);
    if (!(t > 0.0f)) { return rgb; }
    float h;
    if (mx == e.x) { h = (e.y - e.z) / d; } else if (mx == e.y) { h = (e.z - e.x) / d + 2.0f; } else { h = (e.x - e.y) / d + 4.0f; }
    h *= 60.0f;
    if (h < 0.0f) { h += 360.0f; }
    float4 adj = float4(0.0f);
    for (int f = 0; f < 6; f++) {
        float dist = fabs(h - float(f) * 60.0f);
        if (dist > 180.0f) { dist = 360.0f - dist; }
        float wgt = 1.0f - cc_smoothstep(0.0f, 60.0f, dist);
        adj += wgt * float4(u[f * 4], u[f * 4 + 1], u[f * 4 + 2], u[f * 4 + 3]);
    }
    adj *= t;
    float c = 1.0f - e.x, m = 1.0f - e.y, y = 1.0f - e.z;
    float k = min(c, min(m, y));
    float k2 = clamp(k * (1.0f + adj.w), 0.0f, 1.0f);
    float3 o = clamp(float3(c * (1.0f + adj.x), m * (1.0f + adj.y), y * (1.0f + adj.z)) + (k2 - k), float3(0.0f), float3(1.0f));
    return float3(bc_decode(1.0f - o.x), bc_decode(1.0f - o.y), bc_decode(1.0f - o.z));
}
"""#

    public static let source = MetalColorCommon.source + MetalBaseCurve.function + function + #"""

kernel void selectivecolorBuf(device const float4 *src [[buffer(0)]], device float4 *dst [[buffer(1)]], constant float *u [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(selectivecolor_apply(c.rgb, u), c.a);
}
"""#
}

public enum MetalRelight {
    /// Uniforms: u[0] the change in EV, u[1] the centre (EV over middle grey), u[2] the full width at half maximum (EV).
    public static let function = #"""

static float3 relight_apply(float3 rgb, constant float *u) {
    float y = max(cc_luminance(rgb), 1e-6f);
    float b = log2(y / 0.18f);
    float sigma = max(u[2], 1e-6f) / 2.3548200450309493f;
    float d = (isfinite(b) ? b : u[1]) - u[1];
    return rgb * exp2(u[0] * exp(-d * d / (2.0f * sigma * sigma)));
}
"""#

    public static let source = MetalColorCommon.source + function + #"""

kernel void relightBuf(device const float4 *src [[buffer(0)]], device float4 *dst [[buffer(1)]], constant float *u [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(relight_apply(c.rgb, u), c.a);
}
"""#
}
