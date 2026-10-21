// Method: a tanh shoulder on scene luminance, the same maths as HighlightRolloff in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `HighlightRolloff`. Uniforms: u[0] the white, u[1] the knee fraction, u[2] the amount. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalHighlightRolloff {
    public static let function: String = {

        return """

        static float3 highlightrolloff_apply(float3 rgb, constant float *u) {
            float y = cc_luminance(rgb);
            if (!(y > 0.0f) || !isfinite(y)) { return rgb; }
            float k = u[1] * u[0];
            float y2 = y > k ? k + (u[0] - k) * tanh(min((y - k) / (u[0] - k), 20.0f)) : y;
            return rgb * (1.0f + u[2] * (y2 / y - 1.0f));
        }
        """
    }()

    public static let source = MetalColorCommon.source + function + #"""

kernel void highlightrolloffTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(highlightrolloff_apply(c.rgb, u), c.a), gid);
}

kernel void highlightrolloffBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(highlightrolloff_apply(c.rgb, u), c.a);
}
"""#
}
