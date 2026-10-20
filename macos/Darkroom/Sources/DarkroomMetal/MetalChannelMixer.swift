// Method: 3x3 matrix on linear working RGB, one row per output channel; the same rows as ChannelMixer in DarkroomCore, with no clamp.
//
// Metal kernel for the channel mixer card. Uniforms: u[0...2] = the red row, u[3...5] = the green row, u[6...8] = the blue row.
// Checked against the CPU oracle by darkroom-metal-check (mixerBuf), and through Core Image by darkroom-engine-check (E-CM, mixerTex).

public enum MetalChannelMixer {
    public static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    static float3 mixer_apply(float3 c, constant float *u) {
        return float3(dot(float3(u[0], u[1], u[2]), c),
                      dot(float3(u[3], u[4], u[5]), c),
                      dot(float3(u[6], u[7], u[8]), c));
    }

    kernel void mixerTex(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant float *u [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(gid);
        dst.write(float4(mixer_apply(c.rgb, u), c.a), gid);
    }

    kernel void mixerBuf(device const float4 *src [[buffer(0)]],
                         device float4 *dst [[buffer(1)]],
                         constant float *u [[buffer(2)]],
                         uint i [[thread_position_in_grid]]) {
        dst[i] = float4(mixer_apply(src[i].rgb, u), src[i].a);
    }
    """#
}
