// Method: the GPU twin of DarkroomCore.Clipping: blown (any channel at the 255 boundary) red, crushed (any channel at the 0
// boundary) blue, an 85% mix, blown first.

import CoreImage
import DarkroomCore
import Foundation

public enum MetalClipping {
    public static let source = #"""
#include <metal_stdlib>
using namespace metal;

// u: blown boundary, crushed boundary, mix
static float3 clip_tint(float3 rgb, constant float *u) {
    if (max(rgb.r, max(rgb.g, rgb.b)) >= u[0]) { return rgb + (float3(1.0f, 0.1f, 0.1f) - rgb) * u[2]; }
    if (min(rgb.r, min(rgb.g, rgb.b)) <= u[1]) { return rgb + (float3(0.15f, 0.35f, 1.0f) - rgb) * u[2]; }
    return rgb;
}

kernel void clipTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(clip_tint(c.rgb, u), c.a), gid);
}
"""#
}

extension CIBridge {
    /// `image` with its blown and crushed pixels painted (DarkroomCore.Clipping). Display-only.
    public static func clippingOverlay(_ image: CIImage) throws -> CIImage {
        try perPixel(image, source: MetalClipping.source, function: "clipTex",
                     uniforms: [Float(Clipping.blownFrom), Float(Clipping.crushedTo), Float(Clipping.mix)])
    }
}
