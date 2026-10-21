// Method: `Colisa` in DarkroomCore: the colour balance kernel (contrast, OkLab saturation) followed by a brightness gain.
//
// The Metal kernel for `Colisa`. It calls `colorbalance_apply`, so a library that holds it must also hold MetalColorBalance.source:
// `source` does (for darkroom-metal-check's colisaBuf), and the fused library takes only `function`, because it has that source already
// (a kernel defined twice blanks the whole library). Checked against Colisa.apply by darkroom-metal-check (CL-M) and through Core Image
// by darkroom-engine-check (E-CL).
//
// Uniforms: u[0] contrast, u[1] saturation, u[2] vibrance (always 0), u[3] the brightness gain 2^(2 * brightness).

import Foundation

public enum MetalColisa {
    /// The function alone, for the fused library.
    public static let function = #"""

static float3 colisa_apply(float3 rgb, constant float *u) {
    return colorbalance_apply(rgb, u) * u[3];
}
"""#

    public static let source = MetalColorBalance.source + function + #"""

kernel void colisaTex(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float *u [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(colisa_apply(c.rgb, u), c.a), gid);
}

kernel void colisaBuf(device const float4 *src [[buffer(0)]],
                      device float4 *dst [[buffer(1)]],
                      constant float *u [[buffer(2)]],
                      uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(colisa_apply(c.rgb, u), c.a);
}
"""#
}
