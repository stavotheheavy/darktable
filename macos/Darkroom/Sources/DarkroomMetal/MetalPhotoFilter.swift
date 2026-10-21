// Method: a coloured photographic filter with luminosity preserved, the same maths as PhotoFilter in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `PhotoFilter`. Uniforms: u[0...2] the filter colour as a per-channel gain (LiftGammaGain.tint at strength 1), u[3] the density, u[4] the preserve amount. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalPhotoFilter {
    public static let function: String = {

        return """

        static float3 photofilter_apply(float3 rgb, constant float *u) {
            float3 mixed = float3(1.0f) + (float3(u[0], u[1], u[2]) - float3(1.0f)) * u[3];
            float3 filtered = rgb * mixed;
            float before = cc_luminance(rgb), after = cc_luminance(filtered);
            if (!(after > 0.0f) || !(before > 0.0f)) { return filtered; }
            return filtered * (1.0f + u[4] * (before / after - 1.0f));
        }
        """
    }()

    public static let source = MetalColorCommon.source + function + #"""

kernel void photofilterTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(photofilter_apply(c.rgb, u), c.a), gid);
}

kernel void photofilterBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(photofilter_apply(c.rgb, u), c.a);
}
"""#
}
