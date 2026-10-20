// Method: Fritsch and Carlson, "Monotone Piecewise Cubic Interpolation", SIAM J. Numer. Anal. 17(2), 1980.
//
// Metal kernel for the tone curve card. The tangents are computed on the CPU (ToneCurve.tangents in
// DarkroomCore) and passed in as uniforms, so the kernel only evaluates the cubic. The sRGB encode and
// decode are written out here, unclamped, the same formulas as Transfer in DarkroomCore.
// Checked against the CPU oracle by darkroom-metal-check (C1), and through Core Image by darkroom-engine-check (E-TC).
//
// Uniforms: u[0...4] = the node heights y0...y4, u[5...9] = the five tangents.

public enum MetalToneCurve {
    public static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    static float tonecurve_encode(float v) {
        return v <= 0.0031308f ? v * 12.92f : 1.055f * pow(v, 1.0f / 2.4f) - 0.055f;
    }

    static float tonecurve_decode(float e) {
        return e <= 0.04045f ? e / 12.92f : pow((e + 0.055f) / 1.055f, 2.4f);
    }

    static float tonecurve_curve(float e, constant float *u) {
        if (e < 0.0f) { return u[0] + u[5] * e; }
        if (e > 1.0f) { return u[4] + u[9] * (e - 1.0f); }
        int k = min(int(e / 0.25f), 3);
        float s = (e - 0.25f * float(k)) / 0.25f;
        float s2 = s * s, s3 = s2 * s;
        float h00 = 2.0f * s3 - 3.0f * s2 + 1.0f, h10 = s3 - 2.0f * s2 + s;
        float h01 = -2.0f * s3 + 3.0f * s2, h11 = s3 - s2;
        return h00 * u[k] + h10 * 0.25f * u[5 + k] + h01 * u[k + 1] + h11 * 0.25f * u[6 + k];
    }

    static float3 tonecurve_apply(float3 c, constant float *u) {
        float3 e = float3(tonecurve_encode(c.r), tonecurve_encode(c.g), tonecurve_encode(c.b));
        float3 o = float3(tonecurve_curve(e.r, u), tonecurve_curve(e.g, u), tonecurve_curve(e.b, u));
        return float3(tonecurve_decode(o.r), tonecurve_decode(o.g), tonecurve_decode(o.b));
    }

    // texture entry point for the Core Image bridge (CIBridge.perPixel)
    kernel void tonecurveTex(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant float *u [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(gid);
        dst.write(float4(tonecurve_apply(c.rgb, u), c.a), gid);
    }

    // buffer twin of tonecurveTex for darkroom-metal-check (MetalPerPixel.run)
    kernel void tonecurveBuf(device const float4 *src [[buffer(0)]],
                             device float4 *dst [[buffer(1)]],
                             constant float *u [[buffer(2)]],
                             uint i [[thread_position_in_grid]]) {
        dst[i] = float4(tonecurve_apply(src[i].rgb, u), src[i].a);
    }
    """#
}
