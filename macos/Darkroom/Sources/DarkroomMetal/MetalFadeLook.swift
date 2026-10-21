// Method: the matte fade on the encoded value, the same maths as FadeLook in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `FadeLook`. Uniforms: u[0] the black lift, u[1] the white drop. Calls bc_encode/bc_decode. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalFadeLook {
    public static let function: String = {

        return """

        static float fl_channel(float v, float black, float white) {
            return bc_decode(black + (1.0f - black - white) * bc_encode(v));
        }

        static float3 fadelook_apply(float3 rgb, constant float *u) {
            return float3(fl_channel(rgb.x, u[0], u[1]), fl_channel(rgb.y, u[0], u[1]), fl_channel(rgb.z, u[0], u[1]));
        }
        """
    }()

    public static let source = MetalColorCommon.source + MetalBaseCurve.function + function + #"""

kernel void fadelookTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(fadelook_apply(c.rgb, u), c.a), gid);
}

kernel void fadelookBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(fadelook_apply(c.rgb, u), c.a);
}
"""#
}
