// Method: a monotone cubic on OkLab lightness with the chroma kept, the same maths as LumaCurve in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `LumaCurve`. Uniforms: ToneCurve.uniforms (25). Uses tonecurve_curve, so a library that holds it holds MetalToneCurve.source. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalLumaCurve {
    public static let function: String = {

        return """

        static float3 lumacurve_apply(float3 rgb, constant float *u) {
            float3 lab = cc_to_oklab(rgb);
            float l = clamp(isnan(lab.x) ? 0.0f : lab.x, 0.0f, 1.0f);
            lab.x = tonecurve_curve(l, u);
            return cc_from_oklab(lab);
        }
        """
    }()

    public static let source = MetalColorCommon.source + MetalToneCurve.source + function + #"""

kernel void lumacurveTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(lumacurve_apply(c.rgb, u), c.a), gid);
}

kernel void lumacurveBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(lumacurve_apply(c.rgb, u), c.a);
}
"""#
}
