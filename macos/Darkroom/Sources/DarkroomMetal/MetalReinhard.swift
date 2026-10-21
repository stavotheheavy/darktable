// Method: the extended Reinhard operator on luminance, the same maths as Reinhard in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `Reinhard`. Uniforms: u[0] the white, u[1] the amount. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalReinhard {
    public static let function: String = {

        return """

        static float3 reinhard_apply(float3 rgb, constant float *u) {
            float y = cc_luminance(rgb);
            if (!(y > 0.0f) || !isfinite(y)) { return rgb; }
            float ld = y * (1.0f + y / (u[0] * u[0])) / (1.0f + y);
            return rgb * (1.0f + u[1] * (ld / y - 1.0f));
        }
        """
    }()

    public static let source = MetalColorCommon.source + function + #"""

kernel void reinhardTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(reinhard_apply(c.rgb, u), c.a), gid);
}

kernel void reinhardBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(reinhard_apply(c.rgb, u), c.a);
}
"""#
}
