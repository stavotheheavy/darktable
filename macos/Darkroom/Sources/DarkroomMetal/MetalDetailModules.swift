// Method: the GPU twins of DarkroomCore's Deconvolution (Richardson-Lucy), ChromaDenoise (guided filter on the OkLab a and b planes), MedianDenoise, Deband,
// SkinSmooth, TextureBands and Halation. They are built from the pieces the engine already has: the three-box blur (CIBridge.blur), the guided filter
// (CIBridge.guided), per-pixel combine kernels, and one gather kernel (the median, through PerPixelManyProcessor's `reach`).

import CoreImage
import DarkroomCore
import Foundation

extension CIBridge {
    // MARK: deconvolution

    private static let deconvSource = MetalColorCommon.source + #"""

    kernel void deconvRatioTex(texture2d<float, access::read> d [[texture(0)]], texture2d<float, access::read> b [[texture(1)]],
                               texture2d<float, access::write> dst [[texture(2)]],
                               constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = d.read(uint2(int2(gid) + off[0]));
        float4 v = b.read(uint2(int2(gid) + off[1]));
        dst.write(float4(max(c.rgb, float3(0.0f)) / max(v.rgb, float3(u[0])), c.a), gid);
    }

    kernel void deconvUpdateTex(texture2d<float, access::read> est [[texture(0)]], texture2d<float, access::read> corr [[texture(1)]],
                                texture2d<float, access::write> dst [[texture(2)]],
                                constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 e = est.read(uint2(int2(gid) + off[0]));
        float4 k = corr.read(uint2(int2(gid) + off[1]));
        dst.write(float4(e.rgb * clamp(k.rgb, float3(u[0]), float3(u[1])), e.a), gid);
    }

    kernel void deconvMixTex(texture2d<float, access::read> d [[texture(0)]], texture2d<float, access::read> est [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = d.read(uint2(int2(gid) + off[0]));
        float4 e = est.read(uint2(int2(gid) + off[1]));
        dst.write(float4(c.rgb + u[0] * (e.rgb - c.rgb), c.a), gid);
    }
    """#

    /// DarkroomCore.Deconvolution.apply on the GPU.
    public static func deconvolve(_ image: CIImage, radius: Double, iterations: Int, amount: Double) throws -> CIImage {
        guard amount != 0, radius > 0, iterations > 0 else { return image }
        var estimate = image
        for _ in 0..<iterations {
            let blurred = try blur(estimate, radius: radius)
            let ratio = try combine([image, blurred], source: deconvSource, function: "deconvRatioTex", uniforms: [Float(Deconvolution.floor)])
            let correction = try blur(ratio, radius: radius)
            estimate = try combine([estimate, correction], source: deconvSource, function: "deconvUpdateTex",
                                   uniforms: [Float(Deconvolution.lowGain), Float(Deconvolution.highGain)])
        }
        return try combine([image, estimate], source: deconvSource, function: "deconvMixTex", uniforms: [Float(amount)])
    }

    // MARK: chroma denoise

    private static let chromaSource = MetalColorCommon.source + #"""

    kernel void chromaToLabTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                               constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        dst.write(float4(cc_to_oklab(c.rgb), c.a), gid);
    }

    kernel void chromaMixTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::read> smooth [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        float3 lab = cc_to_oklab(c.rgb);
        float3 s = smooth.read(uint2(int2(gid) + off[1])).rgb;
        dst.write(float4(cc_from_oklab(float3(lab.x, lab.y + u[0] * (s.y - lab.y), lab.z + u[0] * (s.z - lab.z))), c.a), gid);
    }
    """#

    /// DarkroomCore.ChromaDenoise.apply on the GPU.
    public static func chromaDenoise(_ image: CIImage, radius: Int, amount: Double) throws -> CIImage {
        guard amount != 0, radius > 0 else { return image }
        let lab = try combine([image], source: chromaSource, function: "chromaToLabTex", uniforms: [0])
        let smooth = try guided(lab, guide: image, radius: radius, eps: ChromaDenoise.eps)
        return try combine([image, smooth], source: chromaSource, function: "chromaMixTex", uniforms: [Float(amount)])
    }

    // MARK: median

    private static let medianSource = MetalColorCommon.source + #"""

    kernel void medianTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                          constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], constant float4 *geom [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int r = int(u[0] + 0.5f);
        float W = geom[0].z, H = geom[0].w;
        int2 a = int2(int(geom[0].x + 0.5f) + int(gid.x), int(geom[0].y + 0.5f) + int(gid.y));
        float4 centre = src.read(uint2(int2(gid) + off[0]));
        float3 med = float3(0.0f);
        for (int c = 0; c < 3; c++) {
            float v[25];
            int n = 0;
            for (int dy = -r; dy <= r; dy++) {
                for (int dx = -r; dx <= r; dx++) {
                    v[n++] = src.read(uint2(int2(gid) + off[0] + int2(clamp(a.x + dx, 0, int(W) - 1) - a.x, clamp(a.y + dy, 0, int(H) - 1) - a.y)))[c];
                }
            }
            for (int i = 1; i < n; i++) {
                float key = v[i];
                int j = i - 1;
                while (j >= 0 && v[j] > key) { v[j + 1] = v[j]; j--; }
                v[j + 1] = key;
            }
            med[c] = v[n / 2];
        }
        dst.write(float4(centre.rgb + u[1] * (med - centre.rgb), centre.a), gid);
    }
    """#

    /// DarkroomCore.MedianDenoise.apply on the GPU (radius 1 or 2).
    public static func medianDenoise(_ image: CIImage, radius: Int, amount: Double) throws -> CIImage {
        guard amount != 0, radius > 0 else { return image }
        let ext = image.extent
        let out = try PerPixelManyProcessor.apply(withExtent: ext, inputs: [image],
                                                  arguments: ["function": "medianTex", "uniforms": [Float(min(radius, 2)), Float(amount)], "source": medianSource,
                                                              "reach": min(radius, 2), "clampToFrame": true,
                                                              "extent": [Double(ext.minX), Double(ext.minY), Double(ext.width), Double(ext.height)]])
        return out
    }

    // MARK: deband

    private static let debandSource = MetalColorCommon.source + MetalBaseCurve.function + #"""

    kernel void debandMixTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::read> blur [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        float3 b = blur.read(uint2(int2(gid) + off[1])).rgb;
        float3 de = float3(bc_encode(c.r), bc_encode(c.g), bc_encode(c.b)) - float3(bc_encode(b.r), bc_encode(b.g), bc_encode(b.b));
        float d = max(max(fabs(de.x), fabs(de.y)), fabs(de.z));
        float wgt = u[1] * (1.0f - cc_smoothstep(0.0f, u[0], d));
        dst.write(float4(c.rgb + wgt * (b - c.rgb), c.a), gid);
    }
    """#

    /// DarkroomCore.Deband.apply on the GPU.
    public static func deband(_ image: CIImage, radius: Double, threshold: Double, strength: Double) throws -> CIImage {
        guard strength != 0, radius > 0 else { return image }
        return try combine([image, try blur(image, radius: radius)], source: debandSource, function: "debandMixTex", uniforms: [Float(threshold), Float(strength)])
    }

    // MARK: skin smoothing

    private static let skinSource = MetalColorCommon.source + MetalMask.prelude + MetalMaskColour.source + #"""

    kernel void skinMixTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::read> smooth [[texture(1)]],
                           texture2d<float, access::write> dst [[texture(2)]],
                           constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        float3 s = smooth.read(uint2(int2(gid) + off[1])).rgb;
        float m = mask_colour(u + 1, c.rgb);
        dst.write(float4(c.rgb + u[0] * m * (s - c.rgb), c.a), gid);
    }
    """#

    /// DarkroomCore.SkinSmooth.apply on the GPU.
    public static func skinSmooth(_ image: CIImage, radius: Int, amount: Double, hueDegrees: Double, widthDegrees: Double) throws -> CIImage {
        guard amount != 0, radius > 0 else { return image }
        let smooth = try guided(image, radius: radius, eps: SkinSmooth.eps)
        let p = SkinSmooth.params(hueDegrees: hueDegrees, widthDegrees: widthDegrees).map { Float($0) }
        return try combine([image, smooth], source: skinSource, function: "skinMixTex", uniforms: [Float(amount)] + p)
    }

    // MARK: texture bands

    private static let textureSource = MetalColorCommon.source + #"""

    // sNew = s + amount * (b1 - b3), as (s, s, s)
    kernel void textureBandTex(texture2d<float, access::read> s [[texture(0)]], texture2d<float, access::read> b1 [[texture(1)]],
                               texture2d<float, access::read> b3 [[texture(2)]], texture2d<float, access::write> dst [[texture(3)]],
                               constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float v = s.read(uint2(int2(gid) + off[0])).r + u[0] * (b1.read(uint2(int2(gid) + off[1])).r - b3.read(uint2(int2(gid) + off[2])).r);
        dst.write(float4(v, v, v, 1.0f), gid);
    }
    """#

    /// DarkroomCore.TextureBands.apply on the GPU. The coarse image is the fine blur blurred again (not a second blur of the source): two blurs of the same
    /// image in one kernel get aliased by Core Image.
    public static func textureBands(_ image: CIImage, radiusPixels: Double, amount: Double) throws -> CIImage {
        let r1 = Blur.radius(px: radiusPixels), r3 = Blur.radius(px: 3 * radiusPixels)
        guard amount != 0, r1 > 0 else { return image }
        let s = try sqrtLuminance(image)
        let fine = try blur(s, radius: r1)
        let sNew = try combine([s, fine, try blur(fine, radius: r3)], source: textureSource, function: "textureBandTex", uniforms: [Float(amount)])
        return try applying(sqrtLuminance: sNew, to: image)
    }

    // MARK: low-pass

    /// DarkroomCore.LowPass.apply on the GPU: the blurred square-root luminance given back as a gain.
    public static func lowPass(_ image: CIImage, radius: Double) throws -> CIImage {
        guard radius > 0 else { return image }
        return try applying(sqrtLuminance: try blur(try sqrtLuminance(image), radius: radius), to: image)
    }

    // MARK: halation

    private static let halationSource = MetalColorCommon.source + #"""

    kernel void halBrightTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                             constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        dst.write(float4(c.rgb * cc_smoothstep(u[0], u[1], cc_luminance(c.rgb)), c.a), gid);
    }

    kernel void halAddTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::read> glow [[texture(1)]],
                          texture2d<float, access::write> dst [[texture(2)]],
                          constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        float3 g = glow.read(uint2(int2(gid) + off[1])).rgb;
        dst.write(float4(c.rgb + u[3] * float3(u[0], u[1], u[2]) * g, c.a), gid);
    }
    """#

    /// DarkroomCore.Halation.apply on the GPU.
    public static func halation(_ image: CIImage, strength: Double, radius: Double, tint: SIMD3<Double>) throws -> CIImage {
        guard strength != 0 else { return image }
        let bright = try combine([image], source: halationSource, function: "halBrightTex", uniforms: [Float(Bloom.kneeLow), Float(Bloom.kneeHigh)])
        let glow = try blur(bright, radius: radius)
        return try combine([image, glow], source: halationSource, function: "halAddTex", uniforms: [Float(tint.x), Float(tint.y), Float(tint.z), Float(strength)])
    }
}
