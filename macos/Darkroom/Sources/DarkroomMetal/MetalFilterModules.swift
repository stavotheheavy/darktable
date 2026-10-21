// Method: the GPU twins of DarkroomCore's SurfaceBlur, LensBlur, MotionBlur, RadialBlur, Diffusion and Kuwahara. The surface blur is the guided filter and a mix; the others are
// gather kernels through PerPixelManyProcessor's `reach` (the input is clamped to its extent, so a read past the frame is the oracle's clamped read), the blurs sampling
// bilinearly where the oracles do.

import CoreImage
import DarkroomCore
import Foundation

extension CIBridge {
    private static let gatherPrelude = MetalColorCommon.source + #"""

    // the pixel at absolute (X, Y) of this thread's tile is `base + (X, Y)`: base = gid + off[0] - (ax, ay)
    // the texel `d` away from absolute position `a`, clamped into the frame (p is this thread's own texel): a gather never reads outside the frame
    static int2 gb_clamp(int2 p, int2 a, int2 d, float W, float H) {
        return p + int2(clamp(a.x + d.x, 0, int(W) - 1) - a.x, clamp(a.y + d.y, 0, int(H) - 1) - a.y);
    }

    static float3 gb_bilinear(texture2d<float, access::read> src, int2 base, float2 p, float W, float H) {
        float x = clamp(isfinite(p.x) ? p.x : 0.0f, 0.0f, W - 1.0f), y = clamp(isfinite(p.y) ? p.y : 0.0f, 0.0f, H - 1.0f);
        int x0 = int(floor(x)), y0 = int(floor(y));
        int x1 = min(x0 + 1, int(W) - 1), y1 = min(y0 + 1, int(H) - 1);
        float fx = x - float(x0), fy = y - float(y0);
        float3 a = src.read(uint2(base + int2(x0, y0))).rgb, b = src.read(uint2(base + int2(x1, y0))).rgb;
        float3 c = src.read(uint2(base + int2(x0, y1))).rgb, d = src.read(uint2(base + int2(x1, y1))).rgb;
        return (a * (1.0f - fx) + b * fx) * (1.0f - fy) + (c * (1.0f - fx) + d * fx) * fy;
    }
    """#

    private static func gather(_ image: CIImage, source: String, function: String, uniforms: [Float], reach: Int) throws -> CIImage {
        let ext = image.extent
        let out = try PerPixelManyProcessor.apply(withExtent: ext, inputs: [image],
                                                  arguments: ["function": function, "uniforms": uniforms, "source": source, "reach": reach, "clampToFrame": true,
                                                              "extent": [Double(ext.minX), Double(ext.minY), Double(ext.width), Double(ext.height)]])
        return out
    }

    // MARK: surface blur

    private static let mixSource = MetalColorCommon.source + #"""

    kernel void mixTowardTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::read> other [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        float3 o = other.read(uint2(int2(gid) + off[1])).rgb;
        dst.write(float4(c.rgb + u[0] * (o - c.rgb), c.a), gid);
    }
    """#

    /// DarkroomCore.SurfaceBlur.apply on the GPU.
    public static func surfaceBlur(_ image: CIImage, radius: Int, eps: Double, amount: Double) throws -> CIImage {
        guard amount != 0, radius > 0 else { return image }
        return try combine([image, try guided(image, radius: radius, eps: eps)], source: mixSource, function: "mixTowardTex", uniforms: [Float(amount)])
    }

    // MARK: lens blur

    private static let lensSource = gatherPrelude + #"""

    kernel void lensBlurTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                            constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int R = int(u[0] + 0.5f);
        float W = geom[0].z, H = geom[0].w;
        int2 a = int2(int(geom[0].x + 0.5f) + int(gid.x), int(geom[0].y + 0.5f) + int(gid.y));
        float3 sum = float3(0.0f);
        float wsum = 0.0f;
        for (int dy = -R; dy <= R; dy++) {
            for (int dx = -R; dx <= R; dx++) {
                if (dx * dx + dy * dy > R * R) { continue; }
                float3 p = src.read(uint2(gb_clamp(int2(gid) + off[0], a, int2(dx, dy), W, H))).rgb;
                float wt = 1.0f + u[1] * cc_smoothstep(\#(String(format: "%.9ff", Bloom.kneeLow)), \#(String(format: "%.9ff", Bloom.kneeHigh)), cc_luminance(p));
                sum += p * wt;
                wsum += wt;
            }
        }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        dst.write(float4(c.rgb + u[2] * (sum / wsum - c.rgb), c.a), gid);
    }
    """#

    /// DarkroomCore.LensBlur.apply on the GPU.
    public static func lensBlur(_ image: CIImage, radius: Int, boost: Double, amount: Double) throws -> CIImage {
        guard amount != 0, radius > 0 else { return image }
        return try gather(image, source: lensSource, function: "lensBlurTex", uniforms: [Float(radius), Float(boost), Float(amount)], reach: radius)
    }

    // MARK: motion and radial blur

    private static let motionSource = gatherPrelude + #"""

    kernel void motionBlurTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                              constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float W = geom[0].z, H = geom[0].w;
        int ax = int(geom[0].x + 0.5f) + int(gid.x), ay = int(geom[0].y + 0.5f) + int(gid.y);
        int2 base = int2(gid) + off[0] - int2(ax, ay);
        int L = int(u[0] + 0.5f);
        float3 sum = float3(0.0f);
        for (int k = -L; k <= L; k++) {
            sum += gb_bilinear(src, base, float2(float(ax) + float(k) * u[1], float(ay) + float(k) * u[2]), W, H);
        }
        dst.write(float4(sum / float(2 * L + 1), src.read(uint2(int2(gid) + off[0])).a), gid);
    }

    // u[0] spin (0/1), u[1] amount, u[2], u[3] the centre in frame pixels, u[4] the samples each side
    kernel void radialBlurTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                              constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float W = geom[0].z, H = geom[0].w;
        int ax = int(geom[0].x + 0.5f) + int(gid.x), ay = int(geom[0].y + 0.5f) + int(gid.y);
        int2 base = int2(gid) + off[0] - int2(ax, ay);
        float rx = float(ax) - u[2], ry = float(ay) - u[3];
        int S = int(u[4] + 0.5f);
        float3 sum = float3(0.0f);
        for (int k = -S; k <= S; k++) {
            float f = float(k) / float(S);
            float2 p;
            if (u[0] > 0.5f) {
                float a = f * u[1] * \#(String(format: "%.9ff", RadialBlur.spinExtentDegrees * Double.pi / 180));
                p = float2(u[2] + rx * cos(a) - ry * sin(a), u[3] + rx * sin(a) + ry * cos(a));
            } else {
                float s = 1.0f + f * u[1] * \#(String(format: "%.9ff", RadialBlur.zoomExtent));
                p = float2(u[2] + rx * s, u[3] + ry * s);
            }
            sum += gb_bilinear(src, base, p, W, H);
        }
        dst.write(float4(sum / float(2 * S + 1), src.read(uint2(int2(gid) + off[0])).a), gid);
    }
    """#

    /// DarkroomCore.MotionBlur.apply on the GPU.
    public static func motionBlur(_ image: CIImage, length: Int, angleDegrees: Double) throws -> CIImage {
        guard length > 0 else { return image }
        let t = angleDegrees * .pi / 180
        return try gather(image, source: motionSource, function: "motionBlurTex", uniforms: [Float(length), Float(cos(t)), Float(-sin(t))], reach: length + 2)
    }

    /// DarkroomCore.RadialBlur.apply on the GPU.
    public static func radialBlur(_ image: CIImage, spin: Bool, amount: Double, centreX: Double, centreY: Double) throws -> CIImage {
        guard amount != 0 else { return image }
        let w = Int(image.extent.width.rounded()), h = Int(image.extent.height.rounded())
        return try gather(image, source: motionSource, function: "radialBlurTex",
                          uniforms: [spin ? 1 : 0, Float(amount), Float(centreX * Double(w - 1)), Float(centreY * Double(h - 1)), Float(RadialBlur.samples(width: w, height: h, spin: spin, amount: amount))],
                          reach: RadialBlur.reach(width: w, height: h, spin: spin, amount: amount))
    }

    // MARK: diffusion

    private static let diffusionSource = gatherPrelude + #"""

    static float3 diff_read(texture2d<float, access::read> src, int2 t, float sq) {
        float3 v = src.read(uint2(t)).rgb;
        return sq > 0.5f ? sqrt(max(v, float3(0.0f))) : v;
    }

    // one Perona-Malik step: u[0] lambda, u[1] K, u[2] 1 on the first step (the input is the scene value: its square root is taken on read), u[3] 1 on the last
    // step (the result is squared back). Folding the conversions into the steps keeps every pass the same reach-1 gather.
    kernel void diffStepTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                            constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int2 p = int2(gid) + off[0];
        float W = geom[0].z, H = geom[0].w;
        int2 a = int2(int(geom[0].x + 0.5f) + int(gid.x), int(geom[0].y + 0.5f) + int(gid.y));
        float3 c = diff_read(src, p, u[2]);
        float3 flow = float3(0.0f);
        const int2 dirs[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
        for (int i = 0; i < 4; i++) {
            float3 d = diff_read(src, gb_clamp(p, a, dirs[i], W, H), u[2]) - c;
            flow += d / (1.0f + (d * d) / (u[1] * u[1]));
        }
        float3 o = c + u[0] * flow;
        if (u[3] > 0.5f) { o = o * o; }
        dst.write(float4(o, src.read(uint2(p)).a), gid);
    }
    """#

    /// DarkroomCore.Diffusion.apply on the GPU: n steps in the square-root domain (the root taken in the first step, the square in the last).
    public static func diffuse(_ image: CIImage, iterations: Int, threshold: Double) throws -> CIImage {
        guard iterations > 0 else { return image }
        var u = image
        for i in 0..<iterations {
            u = try gather(u, source: diffusionSource, function: "diffStepTex",
                           uniforms: [Float(Diffusion.lambda), Float(threshold), i == 0 ? 1 : 0, i == iterations - 1 ? 1 : 0], reach: 1)
        }
        return u
    }

    // MARK: Kuwahara

    private static let kuwaharaSource = gatherPrelude + #"""

    kernel void kuwaharaTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                            constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int R = int(u[0] + 0.5f);
        int2 p = int2(gid) + off[0];
        float W = geom[0].z, H = geom[0].w;
        int2 a = int2(int(geom[0].x + 0.5f) + int(gid.x), int(geom[0].y + 0.5f) + int(gid.y));
        float4 centre = src.read(uint2(p));
        float bestVar = INFINITY;
        float3 bestMean = centre.rgb;
        const int2 quads[4] = { int2(-1, -1), int2(1, -1), int2(-1, 1), int2(1, 1) };
        for (int q = 0; q < 4; q++) {
            float3 sum = float3(0.0f);
            float ls = 0.0f, lq = 0.0f;
            for (int j = 0; j <= R; j++) {
                for (int i = 0; i <= R; i++) {
                    float3 v = src.read(uint2(gb_clamp(p, a, int2(quads[q].x * i, quads[q].y * j), W, H))).rgb;
                    float l = cc_luminance(v);
                    sum += v; ls += l; lq += l * l;
                }
            }
            float n = float((R + 1) * (R + 1));
            float variance = lq / n - (ls / n) * (ls / n);
            if (variance < bestVar) { bestVar = variance; bestMean = sum / n; }
        }
        dst.write(float4(centre.rgb + u[1] * (bestMean - centre.rgb), centre.a), gid);
    }
    """#

    /// DarkroomCore.Kuwahara.apply on the GPU.
    public static func kuwahara(_ image: CIImage, radius: Int, amount: Double) throws -> CIImage {
        guard amount != 0, radius > 0 else { return image }
        return try gather(image, source: kuwaharaSource, function: "kuwaharaTex", uniforms: [Float(radius), Float(amount)], reach: radius)
    }
}
