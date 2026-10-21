// Method: a soft tanh limit on OkLab chroma, the same maths as ChromaLimit in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `ChromaLimit`. Uniform: u[0] the limit. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalChromaLimit {
    public static let function: String = {
        func f(_ x: Double) -> String { String(format: "%.9ff", x) }
        return """

        static float3 chromalimit_apply(float3 rgb, constant float *u) {
            float m = u[0];
            if (!(m < \(f(ChromaLimit.off)))) { return rgb; }
            float3 lab = cc_to_oklab(rgb);
            float c = length(lab.yz);
            if (!(c > 0.0f) || !isfinite(c)) { return rgb; }
            float k = \(f(ChromaLimit.kneeFraction)) * m;
            float c2 = c > k ? k + (m - k) * tanh(min((c - k) / (m - k), 20.0f)) : c;
            lab.yz *= c2 / c;
            return cc_from_oklab(lab);
        }
        """
    }()

    public static let source = MetalColorCommon.source + function + #"""

kernel void chromalimitTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(chromalimit_apply(c.rgb, u), c.a), gid);
}

kernel void chromalimitBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(chromalimit_apply(c.rgb, u), c.a);
}
"""#
}
