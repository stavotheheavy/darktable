// Method: the photographic negative on the sRGB-encoded value (IEC 61966-2-1), the same maths as `Invert` in DarkroomCore.
//
// The Metal kernel for `Invert`. Checked against Invert.apply by darkroom-metal-check (invertBuf) and through Core Image by
// darkroom-engine-check (E-IV).
//
// Uniforms: none. The kernels still take the buffer, so every per-pixel kernel is called the same way (pass one zero).

import Foundation

public enum MetalInvert {
    public static let source = MetalColorCommon.source + #"""

static float inv_channel(float v) {
    // NaN is black; clamp() on a NaN is not defined, so test it first
    float x = isnan(v) ? 0.0f : clamp(v, 0.0f, 1.0f);
    float e = x <= 0.0031308f ? x * 12.92f : 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
    float n = 1.0f - e;
    return n <= 0.04045f ? n / 12.92f : pow((n + 0.055f) / 1.055f, 2.4f);
}

static float3 invert_apply(float3 rgb, constant float *u) {
    return float3(inv_channel(rgb.x), inv_channel(rgb.y), inv_channel(rgb.z));
}

kernel void invertTex(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float *u [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(invert_apply(c.rgb, u), c.a), gid);
}

kernel void invertBuf(device const float4 *src [[buffer(0)]],
                      device float4 *dst [[buffer(1)]],
                      constant float *u [[buffer(2)]],
                      uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(invert_apply(c.rgb, u), c.a);
}
"""#
}
