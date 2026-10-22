// Method: the GPU twins of DarkroomCore's NonLocalMeans, BilateralFilter, Emboss, Sketch, Halftone and CloneSpot (gather kernels through PerPixelManyProcessor's `reach`, reading the
// input clamped to its extent as the oracles clamp their reads) and the liquify warp (mode 3 of the remap kernel).

import CoreImage
import DarkroomCore
import Foundation

extension CIBridge {
    private static let toolPrelude = MetalColorCommon.source + MetalBaseCurve.function + #"""

    static int2 tb_clamp(int2 p, int2 a, int2 d, float W, float H) {
        return p + int2(clamp(a.x + d.x, 0, int(W) - 1) - a.x, clamp(a.y + d.y, 0, int(H) - 1) - a.y);
    }

    static float3 gb_bilinear2(texture2d<float, access::read> src, int2 base, float2 p, float W, float H) {
        float x = clamp(isfinite(p.x) ? p.x : 0.0f, 0.0f, W - 1.0f), y = clamp(isfinite(p.y) ? p.y : 0.0f, 0.0f, H - 1.0f);
        int x0 = int(floor(x)), y0 = int(floor(y));
        int x1 = min(x0 + 1, int(W) - 1), y1 = min(y0 + 1, int(H) - 1);
        float fx = x - float(x0), fy = y - float(y0);
        float3 a = src.read(uint2(base + int2(x0, y0))).rgb, b = src.read(uint2(base + int2(x1, y0))).rgb;
        float3 c = src.read(uint2(base + int2(x0, y1))).rgb, d = src.read(uint2(base + int2(x1, y1))).rgb;
        return (a * (1.0f - fx) + b * fx) * (1.0f - fy) + (c * (1.0f - fx) + d * fx) * fy;
    }

    static float tool_enc_luma(float3 v) {
        float y = cc_luminance(v);
        return isnan(y) ? 0.0f : bc_encode(clamp(y, 0.0f, 1.0f));
    }
    """#

    private static func gatherMany(_ images: [CIImage], source: String, function: String, uniforms: [Float], reach: Int, outputExtent: CGRect? = nil) throws -> CIImage {
        let ext = outputExtent ?? images[0].extent
        return try PerPixelManyProcessor.apply(withExtent: ext, inputs: images,
                                               arguments: ["function": function, "uniforms": uniforms, "source": source, "reach": reach, "clampToFrame": true,
                                                           "extent": [Double(ext.minX), Double(ext.minY), Double(ext.width), Double(ext.height)]])
    }

    // MARK: non-local means and bilateral

    private static let denoiseSource = toolPrelude + #"""

    static float3 nl_u(texture2d<float, access::read> src, int2 p) { return sqrt(max(src.read(uint2(p)).rgb, float3(0.0f))); }

    // u[0] h, u[1] amount
    kernel void nlMeansTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                           constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int2 p = int2(gid) + off[0];
        float W = geom[0].z, H = geom[0].w;
        int2 a = int2(int(geom[0].x + 0.5f) + int(gid.x), int(geom[0].y + 0.5f) + int(gid.y));
        float3 centre[9];
        for (int j = -1; j <= 1; j++) { for (int i = -1; i <= 1; i++) { centre[(j + 1) * 3 + (i + 1)] = nl_u(src, tb_clamp(p, a, int2(i, j), W, H)); } }
        float3 sum = float3(0.0f);
        float wsum = 0.0f;
        for (int dy = -3; dy <= 3; dy++) {
            for (int dx = -3; dx <= 3; dx++) {
                float d2 = 0.0f;
                for (int j = -1; j <= 1; j++) {
                    for (int i = -1; i <= 1; i++) {
                        float3 diff = nl_u(src, tb_clamp(p, a, int2(dx + i, dy + j), W, H)) - centre[(j + 1) * 3 + (i + 1)];
                        d2 += dot(diff, diff);
                    }
                }
                float wt = exp(-(d2 / 27.0f) / (u[0] * u[0]));
                sum += src.read(uint2(tb_clamp(p, a, int2(dx, dy), W, H))).rgb * wt;
                wsum += wt;
            }
        }
        float4 c = src.read(uint2(p));
        dst.write(float4(c.rgb + u[1] * (sum / wsum - c.rgb), c.a), gid);
    }

    // u[0] radius, u[1] sigma_r, u[2] amount
    kernel void bilateralTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                             constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int R = int(u[0] + 0.5f);
        int2 p = int2(gid) + off[0];
        float W = geom[0].z, H = geom[0].w;
        int2 a = int2(int(geom[0].x + 0.5f) + int(gid.x), int(geom[0].y + 0.5f) + int(gid.y));
        float sigmaS = max(float(R) / 2.0f, 0.5f);
        float3 c = nl_u(src, p);
        float3 sum = float3(0.0f);
        float wsum = 0.0f;
        for (int dy = -R; dy <= R; dy++) {
            for (int dx = -R; dx <= R; dx++) {
                float3 d = nl_u(src, tb_clamp(p, a, int2(dx, dy), W, H)) - c;
                float wt = exp(-float(dx * dx + dy * dy) / (2.0f * sigmaS * sigmaS)) * exp(-dot(d, d) / (2.0f * u[1] * u[1]));
                sum += src.read(uint2(tb_clamp(p, a, int2(dx, dy), W, H))).rgb * wt;
                wsum += wt;
            }
        }
        float4 c0 = src.read(uint2(p));
        dst.write(float4(c0.rgb + u[2] * (sum / wsum - c0.rgb), c0.a), gid);
    }
    """#

    /// DarkroomCore.NonLocalMeans.apply on the GPU.
    public static func nonLocalMeans(_ image: CIImage, h: Double, amount: Double) throws -> CIImage {
        guard amount != 0 else { return image }
        return try gatherMany([image], source: denoiseSource, function: "nlMeansTex", uniforms: [Float(h), Float(amount)],
                              reach: NonLocalMeans.searchRadius + NonLocalMeans.patchRadius)
    }

    /// DarkroomCore.BilateralFilter.apply on the GPU.
    public static func bilateral(_ image: CIImage, radius: Int, range: Double, amount: Double) throws -> CIImage {
        guard amount != 0, radius > 0 else { return image }
        return try gatherMany([image], source: denoiseSource, function: "bilateralTex", uniforms: [Float(radius), Float(range), Float(amount)], reach: radius)
    }

    // MARK: emboss, sketch, halftone

    private static let effectSource = toolPrelude + #"""

    // u[0] cos, u[1] -sin of the light angle, u[2] strength, u[3] amount
    kernel void embossTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                          constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float W = geom[0].z, H = geom[0].w;
        int ax = int(geom[0].x + 0.5f) + int(gid.x), ay = int(geom[0].y + 0.5f) + int(gid.y);
        int2 base = int2(gid) + off[0] - int2(ax, ay);
        float2 p = float2(float(ax), float(ay)), d = float2(u[0], u[1]);
        float a = tool_enc_luma(gb_bilinear2(src, base, p + d, W, H)), b = tool_enc_luma(gb_bilinear2(src, base, p - d, W, H));
        float relief = clamp(0.5f + u[2] * (a - b), 0.0f, 1.0f);
        float4 c = src.read(uint2(int2(gid) + off[0]));
        dst.write(float4(c.rgb + u[3] * (float3(bc_decode(relief)) - c.rgb), c.a), gid);
    }

    // u[0] strength, u[1] amount
    kernel void sketchTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                          constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int2 p = int2(gid) + off[0];
        float W = geom[0].z, H = geom[0].w;
        int2 a = int2(int(geom[0].x + 0.5f) + int(gid.x), int(geom[0].y + 0.5f) + int(gid.y));
        float n[9];
        for (int j = -1; j <= 1; j++) { for (int i = -1; i <= 1; i++) { n[(j + 1) * 3 + (i + 1)] = tool_enc_luma(src.read(uint2(tb_clamp(p, a, int2(i, j), W, H))).rgb); } }
        float gx = (n[2] + 2.0f * n[5] + n[8]) - (n[0] + 2.0f * n[3] + n[6]);
        float gy = (n[6] + 2.0f * n[7] + n[8]) - (n[0] + 2.0f * n[1] + n[2]);
        float line = 1.0f - clamp(u[0] * length(float2(gx, gy)), 0.0f, 1.0f);
        float4 c = src.read(uint2(p));
        dst.write(float4(c.rgb + u[1] * (float3(bc_decode(line)) - c.rgb), c.a), gid);
    }

    // u[0] size, u[1] angle (radians), u[2] colour (0/1), u[3] amount
    kernel void halftoneTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                            constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float W = geom[0].z, H = geom[0].w;
        int ax = int(geom[0].x + 0.5f) + int(gid.x), ay = int(geom[0].y + 0.5f) + int(gid.y);
        float s = u[0], ct = cos(u[1]), st = sin(u[1]);
        float px = float(ax) + 0.5f, py = float(ay) + 0.5f;
        float uu = px * ct + py * st, vv = -px * st + py * ct;
        float cu = floor(uu / s) * s + s / 2.0f, cv = floor(vv / s) * s + s / 2.0f;
        float cx = cu * ct - cv * st, cy = cu * st + cv * ct;
        int sx = clamp(int(floor(cx)), 0, int(W) - 1), sy = clamp(int(floor(cy)), 0, int(H) - 1);
        float3 c = src.read(uint2(int2(gid) + off[0] + int2(sx - ax, sy - ay))).rgb;
        float darkness = 1.0f - tool_enc_luma(c);
        float radius = 0.7071f * s * sqrt(darkness);
        float coverage = (1.0f - cc_smoothstep(radius - 0.5f, radius + 0.5f, length(float2(uu - cu, vv - cv)))) * cc_smoothstep(0.0f, 0.5f, radius);
        float3 ink = u[2] > 0.5f ? c : float3(0.0f);
        float3 outc = float3(1.0f) + (ink - float3(1.0f)) * coverage;
        float4 c0 = src.read(uint2(int2(gid) + off[0]));
        dst.write(float4(c0.rgb + u[3] * (outc - c0.rgb), c0.a), gid);
    }
    """#

    /// DarkroomCore.Emboss.apply on the GPU.
    public static func emboss(_ image: CIImage, angleDegrees: Double, strength: Double, amount: Double) throws -> CIImage {
        guard amount != 0 else { return image }
        let t = angleDegrees * .pi / 180
        return try gatherMany([image], source: effectSource, function: "embossTex", uniforms: [Float(cos(t)), Float(-sin(t)), Float(strength), Float(amount)], reach: 3)
    }

    /// DarkroomCore.Sketch.apply on the GPU.
    public static func sketch(_ image: CIImage, strength: Double, amount: Double) throws -> CIImage {
        guard amount != 0 else { return image }
        return try gatherMany([image], source: effectSource, function: "sketchTex", uniforms: [Float(strength), Float(amount)], reach: 1)
    }

    /// DarkroomCore.Halftone.apply on the GPU.
    public static func halftone(_ image: CIImage, size: Double, angleDegrees: Double, colour: Bool, amount: Double) throws -> CIImage {
        guard amount != 0, size >= 1 else { return image }
        return try gatherMany([image], source: effectSource, function: "halftoneTex", uniforms: [Float(size), Float(angleDegrees * .pi / 180), colour ? 1 : 0, Float(amount)],
                              reach: Halftone.reach(size: size))
    }

    // MARK: clone / heal spot

    private static let spotSource = MetalColorCommon.source + #"""

    // image (0), its blur (1). u[0] offset x, u[1] offset y, u[2] centre x, u[3] centre y, u[4] radius, u[5] feather, u[6] heal, u[7] amount
    kernel void cloneSpotTex(texture2d<float, access::read> img [[texture(0)]], texture2d<float, access::read> blur [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int ax = int(geom[0].x + 0.5f) + int(gid.x), ay = int(geom[0].y + 0.5f) + int(gid.y);
        float4 c = img.read(uint2(int2(gid) + off[0]));
        float wgt = u[7] * (1.0f - cc_smoothstep(u[4] * (1.0f - u[5]), u[4], length(float2(float(ax) - u[2], float(ay) - u[3]))));
        if (!(wgt > 0.0f)) { dst.write(c, gid); return; }
        float W = geom[0].z, H = geom[0].w;
        int2 a = int2(ax, ay), o = int2(int(u[0]), int(u[1]));
        int2 dq = int2(clamp(ax + o.x, 0, int(W) - 1) - ax, clamp(ay + o.y, 0, int(H) - 1) - ay);
        float3 q = img.read(uint2(int2(gid) + off[0] + dq)).rgb;
        float3 bp = blur.read(uint2(int2(gid) + off[1])).rgb, bq = blur.read(uint2(int2(gid) + off[1] + dq)).rgb;
        float bfloor = 0.02f * max(bq.x, max(bq.y, bq.z)) + 1e-6f;
        float3 heal = bp * clamp(q / max(bq, float3(bfloor)), 0.0f, 4.0f);
        dst.write(float4(c.rgb + wgt * (q + u[6] * (heal - q) - c.rgb), c.a), gid);
    }
    """#

    /// DarkroomCore.CloneSpot.apply on the GPU. The kernel clamps its source position into the frame (as the oracle's reads clamp), so nothing outside the frame is requested.
    public static func cloneSpot(_ image: CIImage, spot: CloneSpot.Spot) throws -> CIImage {
        guard spot.amount != 0 else { return image }
        let w = Int(image.extent.width.rounded()), h = Int(image.extent.height.rounded())
        let g = spot.geometry(width: w, height: h)
        let reach = max(abs(g.offset.x), abs(g.offset.y)) + 1
        let r = spot.blurRadius(height: h)
        let blurred = try blur(image, radius: r)
        return try gatherMany([image, blurred], source: spotSource, function: "cloneSpotTex",
                              uniforms: [Float(g.offset.x), Float(g.offset.y), Float(g.centre.x), Float(g.centre.y), Float(g.radius), Float(spot.feather), Float(spot.heal), Float(spot.amount)],
                              reach: reach, outputExtent: image.extent)
    }
}
