// Method: a rotation of OkLab (a, b), the same maths as HueRotate in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `HueRotate`. Uniforms: u[0] the cosine and u[1] the sine of the angle. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalHueRotate {
    public static let function: String = {

        return """

        static float3 huerotate_apply(float3 rgb, constant float *u) {
            float3 lab = cc_to_oklab(rgb);
            float a = lab.y * u[0] - lab.z * u[1], b = lab.y * u[1] + lab.z * u[0];
            return cc_from_oklab(float3(lab.x, a, b));
        }
        """
    }()

    public static let source = MetalColorCommon.source + function + #"""

kernel void huerotateTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(huerotate_apply(c.rgb, u), c.a), gid);
}

kernel void huerotateBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(huerotate_apply(c.rgb, u), c.a);
}
"""#
}
