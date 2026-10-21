// Method: the bleach bypass look on the encoded value, the same maths as BleachBypass in DarkroomCore.

import DarkroomCore
import Foundation

/// The Metal function for `BleachBypass`. Uniform: u[0] the strength. Calls bc_encode/bc_decode. A function (in the fused pass) plus standalone kernels for darkroom-metal-check.
public enum MetalBleachBypass {
    public static let function: String = {
        func f(_ x: Double) -> String { String(format: "%.9ff", x) }
        return """

        static float bb_channel(float v, float y, float s) {
            float d = v + \(f(BleachBypass.desaturation)) * s * (y - v);
            float o = d < 0.5f ? 2.0f * d * y : 1.0f - 2.0f * (1.0f - d) * (1.0f - y);
            return bc_decode(clamp(d + s * (o - d), 0.0f, 1.0f));
        }

        static float3 bleachbypass_apply(float3 rgb, constant float *u) {
            float3 e = float3(bc_encode(rgb.x), bc_encode(rgb.y), bc_encode(rgb.z));
            float y = 0.2126f * e.x + 0.7152f * e.y + 0.0722f * e.z;
            return float3(bb_channel(e.x, y, u[0]), bb_channel(e.y, y, u[0]), bb_channel(e.z, y, u[0]));
        }
        """
    }()

    public static let source = MetalColorCommon.source + MetalBaseCurve.function + function + #"""

kernel void bleachbypassTex(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(bleachbypass_apply(c.rgb, u), c.a), gid);
}

kernel void bleachbypassBuf(device const float4 *src [[buffer(0)]],
                    device float4 *dst [[buffer(1)]],
                    constant float *u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(bleachbypass_apply(c.rgb, u), c.a);
}
"""#
}
