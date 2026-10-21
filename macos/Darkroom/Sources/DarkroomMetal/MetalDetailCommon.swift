// Method: the GPU twin of DarkroomCore.DetailCommon (square-root luminance s = sqrt(Y), Anscombe 1948, and the gain
// Y'/Y that gives a change in s back to the pixel as a scale on all three channels).

import CoreImage
import Foundation

/// Metal helpers the S5 detail cards put in front of their own kernels: `MetalDetailCommon.source + #"""..."""#`.
/// Kernels that read several images take them as textures 0...n-1 with the output at n, `constant float *u [[buffer(0)]]`
/// and `constant int2 *off [[buffer(1)]]`, and read input k at `uint2(int2(gid) + off[k])` (see CIBridge.combine).
public enum MetalDetailCommon {
    public static let source = #"""
#include <metal_stdlib>
using namespace metal;

constant float detailMinLuminance = 1.0e-6f;

static float detail_luminance(float3 rgb) { return dot(rgb, \#(MetalColorCommon.lumaVector)); }
static float detail_sqrt_luma(float3 rgb) { return sqrt(max(detail_luminance(rgb), 0.0f)); }

// DetailCommon.gain: Y'/Y with Y' = max(newS, 0)^2, and 1 at or under the minimum luminance
static float detail_gain(float y, float newS) {
    if (!(y > detailMinLuminance)) { return 1.0f; }
    float s = max(newS, 0.0f);
    return s * s / y;
}

// (s, s, s, alpha) for every pixel
kernel void detailSqrtLumaTex(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(uint2(int2(gid) + off[0]));
    float s = detail_sqrt_luma(c.rgb);
    dst.write(float4(s, s, s, c.a), gid);
}

// the image with its square-root luminance replaced by the plane in texture 1 (any channel): the identity pair
// of detailSqrtLumaTex
kernel void detailApplyTex(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::read> newS [[texture(1)]],
                           texture2d<float, access::write> dst [[texture(2)]],
                           constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(uint2(int2(gid) + off[0]));
    float s = newS.read(uint2(int2(gid) + off[1])).x;
    dst.write(float4(c.rgb * detail_gain(detail_luminance(c.rgb), s), c.a), gid);
}
"""#
}

extension CIBridge {
    /// DarkroomCore.DetailCommon.sqrtLuminance as an image: (s, s, s, alpha).
    public static func sqrtLuminance(_ image: CIImage) throws -> CIImage {
        try combine([image], source: MetalDetailCommon.source, function: "detailSqrtLumaTex", uniforms: [])
    }

    /// `image` with its square-root luminance replaced by `s`'s first channel (DetailCommon.applying).
    public static func applying(sqrtLuminance s: CIImage, to image: CIImage) throws -> CIImage {
        try combine([image, s], source: MetalDetailCommon.source, function: "detailApplyTex", uniforms: [])
    }
}
