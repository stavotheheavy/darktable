// Method: classic levels (black point, white point, gamma from a grey point), from the rgblevels card's formula; sRGB encode and decode as in DarkroomCore's Transfer
import Foundation

/// The Metal kernel for `Levels`. Uniforms: `u[0]` black, `u[1]` white, `u[2]` gamma. The CPU side guards
/// white and grey and computes gamma before the call.
public enum MetalLevels {
    public static let source = #"""
#include <metal_stdlib>
using namespace metal;

static float levels_encode(float v) {
    return v <= 0.0031308f ? v * 12.92f : 1.055f * pow(v, 1.0f / 2.4f) - 0.055f;
}

static float levels_decode(float v) {
    return v <= 0.04045f ? v / 12.92f : pow((v + 0.055f) / 1.055f, 2.4f);
}

static float levels_channel(float v, constant float *u) {
    float t = (levels_encode(v) - u[0]) / (u[1] - u[0]);
    float shaped = t <= 0.0f ? 0.0f : pow(t, u[2]);
    return levels_decode(shaped);
}

static float3 levels_apply(float3 c, constant float *u) {
    return float3(levels_channel(c.x, u), levels_channel(c.y, u), levels_channel(c.z, u));
}

kernel void levelsTex(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float *u [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(levels_apply(c.rgb, u), c.a), gid);
}

kernel void levelsBuf(device const float4 *src [[buffer(0)]],
                      device float4 *dst [[buffer(1)]],
                      constant float *u [[buffer(2)]],
                      uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(levels_apply(c.rgb, u), c.a);
}
"""#
}
