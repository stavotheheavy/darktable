// Method: a monotone cubic per channel, the same maths as ChannelCurves in DarkroomCore: the tone curve kernel's own evaluation, three times.

import DarkroomCore
import Foundation

/// The Metal function for `ChannelCurves`. Uniforms: three ToneCurve.uniforms blocks of 25 (red, green, blue). Uses the tone curve functions, so a library that holds it holds MetalToneCurve.source. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalChannelCurves {
    public static let function: String = {

        return """

        static float3 channelcurves_apply(float3 c, constant float *u) {
            float3 e = float3(tonecurve_encode(c.r), tonecurve_encode(c.g), tonecurve_encode(c.b));
            return float3(tonecurve_decode(tonecurve_curve(e.r, u)), tonecurve_decode(tonecurve_curve(e.g, u + 25)),
                          tonecurve_decode(tonecurve_curve(e.b, u + 50)));
        }
        """
    }()

    public static let source = MetalToneCurve.source + function + #"""

kernel void channelcurvesTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(channelcurves_apply(c.rgb, u), c.a), gid);
}

kernel void channelcurvesBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(channelcurves_apply(c.rgb, u), c.a);
}
"""#
}
