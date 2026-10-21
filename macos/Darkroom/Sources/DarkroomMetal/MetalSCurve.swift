// Method: the bias-and-gain contrast curve on the encoded value, the same maths as SCurve in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `SCurve`. Uniforms: u[0] the exponent k, u[1] the pivot. Calls bc_encode/bc_decode. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalSCurve {
    public static let function: String = {

        return """

        static float sc_channel(float v, float k, float p) {
            float e = bc_encode(v);
            float o = e <= p ? p * pow(e / p, k) : 1.0f - (1.0f - p) * pow((1.0f - e) / (1.0f - p), k);
            return bc_decode(clamp(o, 0.0f, 1.0f));
        }

        static float3 scurve_apply(float3 rgb, constant float *u) {
            return float3(sc_channel(rgb.x, u[0], u[1]), sc_channel(rgb.y, u[0], u[1]), sc_channel(rgb.z, u[0], u[1]));
        }
        """
    }()

    public static let source = MetalColorCommon.source + MetalBaseCurve.function + function + #"""

kernel void scurveTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(scurve_apply(c.rgb, u), c.a), gid);
}

kernel void scurveBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(scurve_apply(c.rgb, u), c.a);
}
"""#
}
