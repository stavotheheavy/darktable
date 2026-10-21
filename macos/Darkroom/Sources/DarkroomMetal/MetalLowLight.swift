// Method: the Purkinje-shift model of LowLight in DarkroomCore, with its luminance range, scotopic weights and tint taken from it at run time.

import DarkroomCore
import Foundation

/// The Metal function for `LowLight`. Uniform: u[0] the strength. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalLowLight {
    public static let function: String = {
        func f(_ x: Double) -> String { String(format: "%.9ff", x) }
        func v(_ x: SIMD3<Double>) -> String { "float3(\(f(x.x)), \(f(x.y)), \(f(x.z)))" }
        return """

        static float3 lowlight_apply(float3 rgb, constant float *u) {
            float y = cc_luminance(rgb);
            float w = u[0] * (1.0f - cc_smoothstep(\(f(LowLight.lumaLow)), \(f(LowLight.lumaHigh)), y));
            if (!(w > 0.0f)) { return rgb; }
            float3 scotopic = dot(\(v(LowLight.scotopicWeights)), rgb) * \(v(LowLight.tint));
            return rgb + w * (scotopic - rgb);
        }
        """
    }()

    public static let source = MetalColorCommon.source + function + #"""

kernel void lowlightTex(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float *u [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(lowlight_apply(c.rgb, u), c.a), gid);
}

kernel void lowlightBuf(device const float4 *src [[buffer(0)]],
                        device float4 *dst [[buffer(1)]],
                        constant float *u [[buffer(2)]],
                        uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(lowlight_apply(c.rgb, u), c.a);
}
"""#
}
