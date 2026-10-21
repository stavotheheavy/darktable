// Method: the cross-processing look on the encoded value, the same maths as CrossProcess in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `CrossProcess`. Uniform: u[0] the amount. Calls bc_encode/bc_decode (MetalBaseCurve.function). A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalCrossProcess {
    public static let function: String = {
        func f(_ x: Double) -> String { String(format: "%.9ff", x) }
        return """

        static float cp_s(float x) { return cc_smoothstep(0.0f, 1.0f, x); }

        static float3 crossprocess_apply(float3 rgb, constant float *u) {
            float a = u[0];
            float3 e = float3(bc_encode(rgb.x), bc_encode(rgb.y), bc_encode(rgb.z));
            float r = e.x + \(f(CrossProcess.kRed)) * a * (cp_s(e.x) - e.x);
            float g = e.y + \(f(CrossProcess.kGreen)) * a * (cp_s(e.y) - e.y);
            float b = e.z - \(f(CrossProcess.kBlue)) * a * (cp_s(e.z) - e.z) + \(f(CrossProcess.blueLift)) * a * (1.0f - e.z);
            return float3(bc_decode(clamp(r, 0.0f, 1.0f)), bc_decode(clamp(g, 0.0f, 1.0f)), bc_decode(clamp(b, 0.0f, 1.0f)));
        }
        """
    }()

    public static let source = MetalColorCommon.source + MetalBaseCurve.function + function + #"""

kernel void crossprocessTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(crossprocess_apply(c.rgb, u), c.a), gid);
}

kernel void crossprocessBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(crossprocess_apply(c.rgb, u), c.a);
}
"""#
}
