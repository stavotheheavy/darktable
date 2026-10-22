// Method: the GPU twins of DarkroomCore's Remap (bilinear warps: radial distortion, lateral chromatic aberration, keystone), TiltShift and Defringe. The warp is one gather
// kernel through PerPixelManyProcessor's `reach` (the largest displacement, computed by Remap.reach), reading four texels per channel; tilt-shift mixes the picture with its
// three-box blur by a position-dependent weight (absolute coordinates from the frame geometry buffer); defringe takes the luminance edge from a blurred luminance plane and the
// fringe colour from the colour-range matte of MetalMaskColour.

import CoreImage
import DarkroomCore
import Foundation

extension CIBridge {
    // MARK: remap

    private static let remapSource = MetalColorCommon.source + #"""

    static float2 rm_source(int mode, float px, float py, float W, float H, constant float *u, int ch) {
        float cx = (W - 1.0f) / 2.0f, cy = (H - 1.0f) / 2.0f;
        // the output position seen through a zoom about the centre (u[5]; 1 is none)
        float x = cx + (px - cx) / u[5], y = cy + (py - cy) / u[5];
        if (mode == 0) {
            float norm = max(length(float2(cx, cy)), 1e-9f);
            float uu = (x - cx) / norm, vv = (y - cy) / norm;
            float r2 = uu * uu + vv * vv;
            float f = 1.0f + u[1] * r2 + u[2] * r2 * r2;
            return float2(cx + (x - cx) * f, cy + (y - cy) * f);
        }
        if (mode == 1) {
            float s = ch == 0 ? 1.0f + u[1] : (ch == 2 ? 1.0f + u[2] : 1.0f);
            return float2(cx + (x - cx) * s, cy + (y - cy) * s);
        }
        if (mode == 3) {
            float px = u[1] * (W - 1.0f), py = u[2] * (H - 1.0f);
            float r = max(u[3] * H, 1e-6f);
            float d = length(float2(x - px, y - py)) / r;
            float f = d < 1.0f ? 1.0f - u[4] * (1.0f - d * d) * (1.0f - d * d) : 1.0f;
            return float2(px + (x - px) * f, py + (y - py) * f);
        }
        float uu = cx > 0.0f ? (x - cx) / cx : 0.0f, vv = cy > 0.0f ? (y - cy) / cy : 0.0f;
        float w = 1.0f + u[1] * uu + u[2] * vv;
        float d = fabs(w) < 1e-6f ? 1e-6f : w;
        return float2(cx + (uu / d) * cx, cy + (vv / d) * cy);
    }

    kernel void remapTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                         constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int mode = int(u[0] + 0.5f);
        float W = geom[0].z, H = geom[0].w;
        int ax = int(geom[0].x + 0.5f) + int(gid.x), ay = int(geom[0].y + 0.5f) + int(gid.y);
        float3 o = float3(0.0f);
        for (int ch = 0; ch < 3; ch++) {
            float2 p = rm_source(mode, float(ax), float(ay), W, H, u, ch);
            float x = clamp(isfinite(p.x) ? p.x : 0.0f, 0.0f, W - 1.0f), y = clamp(isfinite(p.y) ? p.y : 0.0f, 0.0f, H - 1.0f);
            int x0 = int(floor(x)), y0 = int(floor(y));
            int x1 = min(x0 + 1, int(W) - 1), y1 = min(y0 + 1, int(H) - 1);
            float fx = x - float(x0), fy = y - float(y0);
            int2 base = int2(gid) + off[0] - int2(ax, ay);
            float a = src.read(uint2(base + int2(x0, y0)))[ch], b = src.read(uint2(base + int2(x1, y0)))[ch];
            float c = src.read(uint2(base + int2(x0, y1)))[ch], d = src.read(uint2(base + int2(x1, y1)))[ch];
            o[ch] = (a * (1.0f - fx) + b * fx) * (1.0f - fy) + (c * (1.0f - fx) + d * fx) * fy;
        }
        dst.write(float4(o, src.read(uint2(int2(gid) + off[0])).a), gid);
    }
    """#

    /// DarkroomCore.Remap.apply on the GPU.
    public static func remap(_ image: CIImage, kind: Remap.Kind, zoom: Double = 1) throws -> CIImage {
        let ext = image.extent
        let w = Int(ext.width.rounded()), h = Int(ext.height.rounded())
        var u: [Float]
        switch kind {
        case .distortion(let k1, let k2): u = [0, Float(k1), Float(k2), 0, 0]
        case .chromaticAberration(let red, let blue): u = [1, Float(red), Float(blue), 0, 0]
        case .perspective(let kx, let ky): u = [2, Float(kx), Float(ky), 0, 0]
        case .warp(let cx, let cy, let radius, let strength): u = [3, Float(cx), Float(cy), Float(radius), Float(strength)]
        }
        u.append(Float(zoom))
        if case .warp(_, _, _, let strength) = kind { if strength == 0 { return image } } else if u[1] == 0 && u[2] == 0 && zoom == 1 { return image }
        let reach = Remap.reach(kind, width: w, height: h, zoom: zoom)
        let out = try PerPixelManyProcessor.apply(withExtent: ext, inputs: [image],
                                                  arguments: ["function": "remapTex", "uniforms": u, "source": remapSource, "reach": reach, "clampToFrame": true,
                                                              "extent": [Double(ext.minX), Double(ext.minY), Double(ext.width), Double(ext.height)]])
        return out
    }

    // MARK: tilt-shift

    private static let tiltSource = MetalColorCommon.source + #"""

    kernel void tiltMixTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::read> blur [[texture(1)]],
                           texture2d<float, access::write> dst [[texture(2)]],
                           constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float W = geom[0].z, H = geom[0].w;
        float x = float(int(geom[0].x + 0.5f) + int(gid.x)), y = float(int(geom[0].y + 0.5f) + int(gid.y));
        float t = u[1] * 3.14159265358979f / 180.0f;
        float px = x + 0.5f - W / 2.0f, py = y + 0.5f - u[0] * H;
        float d = (-px * sin(t) + py * cos(t)) / H;
        float wgt = u[4] * cc_smoothstep(0.0f, u[3], fabs(d) - u[2] / 2.0f);
        float4 c = src.read(uint2(int2(gid) + off[0]));
        float3 b = blur.read(uint2(int2(gid) + off[1])).rgb;
        dst.write(float4(c.rgb + wgt * (b - c.rgb), c.a), gid);
    }
    """#

    /// DarkroomCore.TiltShift.apply on the GPU.
    public static func tiltShift(_ image: CIImage, radius: Double, position: Double, angleDegrees: Double, bandWidth: Double, transition: Double, amount: Double) throws -> CIImage {
        guard amount != 0, radius > 0 else { return image }
        let ext = image.extent
        let blurred = try blur(image, radius: radius)
        let out = try PerPixelManyProcessor.apply(withExtent: ext, inputs: [image, blurred],
                                                  arguments: ["function": "tiltMixTex", "source": tiltSource,
                                                              "uniforms": [Float(position), Float(angleDegrees), Float(bandWidth), Float(transition), Float(amount)],
                                                              "extent": [Double(ext.minX), Double(ext.minY), Double(ext.width), Double(ext.height)]])
        return out
    }

    // MARK: defringe

    private static let defringeSource = MetalColorCommon.source + MetalMask.prelude + MetalMaskColour.source + #"""

    kernel void defringeLumaTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        float y = cc_luminance(c.rgb);
        dst.write(float4(y, y, y, c.a), gid);
    }

    // u[0] strength, u[1...4] the colour matte (hue, half-width, chroma floor, feather), u[5] edge low, u[6] edge high, u[7] luminance floor
    kernel void defringeMixTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::read> yb [[texture(1)]],
                               texture2d<float, access::write> dst [[texture(2)]],
                               constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        float b = yb.read(uint2(int2(gid) + off[1])).r;
        float edge = cc_smoothstep(u[5], u[6], fabs(cc_luminance(c.rgb) - b) / max(b, u[7]));
        float m = edge * mask_colour(u + 1, c.rgb);
        float3 lab = cc_to_oklab(c.rgb);
        float k = 1.0f - u[0] * m;
        lab.y *= k;
        lab.z *= k;
        dst.write(float4(cc_from_oklab(lab), c.a), gid);
    }
    """#

    /// DarkroomCore.Defringe.apply on the GPU.
    public static func defringe(_ image: CIImage, radius: Double, strength: Double, hueDegrees: Double, widthDegrees: Double) throws -> CIImage {
        guard strength != 0, radius > 0 else { return image }
        let luma = try combine([image], source: defringeSource, function: "defringeLumaTex", uniforms: [0])
        let p = Defringe.params(hueDegrees: hueDegrees, widthDegrees: widthDegrees).map { Float($0) }
        return try combine([image, try blur(luma, radius: radius)], source: defringeSource, function: "defringeMixTex",
                           uniforms: [Float(strength)] + p + [Float(Defringe.edgeLow), Float(Defringe.edgeHigh), Float(Defringe.lumaFloor)])
    }
}
