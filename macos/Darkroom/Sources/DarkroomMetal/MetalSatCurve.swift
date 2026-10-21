// Method: OkLab (Björn Ottosson, "A perceptual color space for image processing", 2020); the same lightness-knot blend as SatCurve in DarkroomCore, with the knots taken from it at run time.

import DarkroomCore
import Foundation

/// The Metal function for `SatCurve`. Uniforms: `u[0]` shadows, `u[1]` mids, `u[2]` highlights (each -1...1).
/// A function only, no kernels: it is compiled into the fused pass.
public enum MetalSatCurve {
    public static let function: String = {
        func f(_ x: Double) -> String { String(format: "%.9ff", x) }
        let k = SatCurve.knots
        return """

        static float3 satcurve_apply(float3 rgb, constant float *u) {
            float3 lab = cc_to_oklab(rgb);
            float L = lab.x;
            float s;
            if (L <= \(f(k[0]))) {
                s = u[0];
            } else if (L >= \(f(k[2]))) {
                s = u[2];
            } else if (L < \(f(k[1]))) {
                float t = cc_smoothstep(\(f(k[0])), \(f(k[1])), L);
                s = u[0] * (1.0f - t) + u[1] * t;
            } else {
                float t = cc_smoothstep(\(f(k[1])), \(f(k[2])), L);
                s = u[1] * (1.0f - t) + u[2] * t;
            }
            float g = max(1.0f + s, 0.0f);
            lab.y *= g;
            lab.z *= g;
            return cc_from_oklab(lab);
        }
        """
    }()

    /// Standalone kernels for darkroom-metal-check (the fused pass uses `function` alone).
    public static let source = MetalColorCommon.source + function + #"""

kernel void satcurveTex(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float *u [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(satcurve_apply(c.rgb, u), c.a), gid);
}

kernel void satcurveBuf(device const float4 *src [[buffer(0)]],
                        device float4 *dst [[buffer(1)]],
                        constant float *u [[buffer(2)]],
                        uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(satcurve_apply(c.rgb, u), c.a);
}
"""#
}
