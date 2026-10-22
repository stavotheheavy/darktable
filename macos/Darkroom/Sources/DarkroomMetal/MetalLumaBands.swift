// Method: a five-band exposure by the own luminance of each pixel, the same maths as LumaBands in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `LumaBands`. Uniforms: u[0...4] the node offsets and u[5...9] the Hermite slopes from `LumaBands.prepared`. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalLumaBands {
    public static let function: String = {

        return """

        constant float lb_centres[5] = { -4.0f, -2.0f, 0.0f, 1.5f, 3.0f };

        static float3 lumabands_apply(float3 rgb, constant float *u) {
            float y = max(cc_luminance(rgb), 1e-6f);
            float b = log2(y / 0.18f);
            if (!isfinite(b)) { b = 0.0f; }
            float g;
            if (b <= lb_centres[0]) { g = u[0]; }
            else if (b >= lb_centres[4]) { g = u[4]; }
            else {
                int k = 0;
                while (k < 3 && b >= lb_centres[k + 1]) { k++; }
                float h = lb_centres[k + 1] - lb_centres[k], t = (b - lb_centres[k]) / h, t2 = t * t, t3 = t2 * t;
                float f0 = lb_centres[k] + u[k], f1 = lb_centres[k + 1] + u[k + 1];
                float f = (2.0f * t3 - 3.0f * t2 + 1.0f) * f0 + (t3 - 2.0f * t2 + t) * h * u[5 + k] + (-2.0f * t3 + 3.0f * t2) * f1 + (t3 - t2) * h * u[5 + k + 1];
                g = f - b;
            }
            return rgb * exp2(g);
        }
        """
    }()

    public static let source = MetalColorCommon.source + function + #"""

kernel void lumabandsTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(lumabands_apply(c.rgb, u), c.a), gid);
}

kernel void lumabandsBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(lumabands_apply(c.rgb, u), c.a);
}
"""#
}
