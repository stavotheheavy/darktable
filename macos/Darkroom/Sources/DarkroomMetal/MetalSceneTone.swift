// Method: the scene tone stage of DarkroomCore.SceneTone (Lottes GDC 2016 on the luminance norm; the BT.2390 Annex 5
// Hermite knee; Fritsch and Carlson 1980 for the monotone limit, which the CPU side applies when it picks the knee).
//
// Metal kernel for the display module. The curve is evaluated in closed form, so there is no table: every number the
// kernel needs arrives as a uniform (SceneTone.uniforms). The maths is the oracle's, line for line.
// Checked against the oracle by darkroom-metal-check and, through Core Image, by darkroom-engine-check (E3, E4).
//
// Uniforms: u[0] grey, u[1] slope, u[2] kneeEV, u[3] kneeValue, u[4] kneeSlope, u[5] shoulderEV, u[6] peak, u[7] purity,
// u[8] ymin, u[10...18] the Rec.2020 to sRGB matrix, row by row, u[19...21] the gain on the input, u[22...30] the working-space
// (linear sRGB) to Rec.2020 matrix. The input is the working space: the gain applies there, then the move to Rec.2020.

import DarkroomCore

public enum MetalSceneTone {
    /// The shared colour helpers (OkLab from DarkroomCore's own matrices), then the stage.
    public static let source = MetalColorCommon.source + #"""

    static float st_curve(float x, constant float *u) {
        float kneeEV = u[2];
        if (x <= kneeEV) { return u[0] * exp2(u[1] * x); }
        float h = u[5];
        float t = min((x - kneeEV) / h, 1.0f);
        float t2 = t * t, t3 = t2 * t;
        float h00 = 2.0f * t3 - 3.0f * t2 + 1.0f, h10 = t3 - 2.0f * t2 + t, h01 = -2.0f * t3 + 3.0f * t2;
        return h00 * u[3] + h10 * h * u[4] + h01 * u[6];
    }

    static float3 st_apply(float3 work, constant float *u) {
        work *= float3(u[19], u[20], u[21]);
        float3 rgb = float3(u[22] * work.x + u[23] * work.y + u[24] * work.z,
                            u[25] * work.x + u[26] * work.y + u[27] * work.z,
                            u[28] * work.x + u[29] * work.y + u[30] * work.z);
        if (!(isfinite(rgb.x) && isfinite(rgb.y) && isfinite(rgb.z))) { return float3(0.0f); }
        float n = 0.2627f * rgb.x + 0.6780f * rgb.y + 0.0593f * rgb.z;
        float ne = max(n, u[8]);
        float x = log2(ne / u[0]);
        float t = st_curve(x, u);
        float3 o = rgb * (t / ne);
        float tt = clamp((x - u[2]) / u[5], 0.0f, 1.0f);
        float h = u[7] * (tt * tt * (3.0f - 2.0f * tt));
        if (h > 0.0f) { o += (float3(t) - o) * h; }
        float3 s = float3(u[10] * o.x + u[11] * o.y + u[12] * o.z,
                          u[13] * o.x + u[14] * o.y + u[15] * o.z,
                          u[16] * o.x + u[17] * o.y + u[18] * o.z);
        float peak = u[6];
        float3 q = s / peak;
        const float eps = 1e-5f;
        if (min(q.x, min(q.y, q.z)) >= -eps && max(q.x, max(q.y, q.z)) <= 1.0f + eps) { return clamp(s, 0.0f, peak); }
        float3 lab = cc_to_oklab(q);
        if (lab.x <= 0.0f) { return float3(0.0f); }
        if (lab.x >= 1.0f) { return float3(peak); }
        float lo = 0.0f, hi = 1.0f;
        for (int i = 0; i < 20; i++) {
            float mid = 0.5f * (lo + hi);
            float3 c = cc_from_oklab(float3(lab.x, lab.y * mid, lab.z * mid));
            if (min(c.x, min(c.y, c.z)) >= -eps && max(c.x, max(c.y, c.z)) <= 1.0f + eps) { lo = mid; } else { hi = mid; }
        }
        s = cc_from_oklab(float3(lab.x, lab.y * lo, lab.z * lo)) * peak;
        return clamp(s, 0.0f, peak);
    }

    // texture entry point for the Core Image bridge (CIBridge.perPixel)
    kernel void scenetoneTex(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant float *u [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(gid);
        dst.write(float4(st_apply(c.rgb, u), c.a), gid);
    }

    // buffer twin of scenetoneTex for darkroom-metal-check (MetalPerPixel.run)
    kernel void scenetoneBuf(device const float4 *src [[buffer(0)]],
                             device float4 *dst [[buffer(1)]],
                             constant float *u [[buffer(2)]],
                             uint i [[thread_position_in_grid]]) {
        dst[i] = float4(st_apply(src[i].rgb, u), src[i].a);
    }
    """#
}
