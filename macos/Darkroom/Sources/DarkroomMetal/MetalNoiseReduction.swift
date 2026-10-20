// Method: the GPU twin of DarkroomCore.NoiseReduction: soft-threshold wavelet shrinkage (Donoho, IEEE Trans. Inf. Theory
// 41, 1995) on the a trous bands (Starck and Murtagh, A&A 288, 1994), luminance in s = sqrt(Y) (Anscombe 1948), colour in
// the ratios rgb / Y renormalised to keep luminance.

import CoreImage
import DarkroomCore
import Foundation

enum MetalNoiseReduction {
    static let source = MetalDetailCommon.source + #"""

// soft threshold: shrink d towards zero by t
static float nr_soft(float d, float t) {
    float m = max(fabs(d) - t, 0.0f);
    return d < 0.0f ? -m : m;
}

// luminance stage: s2 = sm3 + soft(s - sm0) + soft(sm0 - sm1) + soft(sm1 - sm2) + soft(sm2 - sm3), then the gain.
// Inputs: 0 the image, 1 s, 2...5 sm0...sm3; uniforms t0...t3.
kernel void noiseLumaTex(texture2d<float, access::read> img [[texture(0)]],
                         texture2d<float, access::read> s [[texture(1)]],
                         texture2d<float, access::read> sm0 [[texture(2)]],
                         texture2d<float, access::read> sm1 [[texture(3)]],
                         texture2d<float, access::read> sm2 [[texture(4)]],
                         texture2d<float, access::read> sm3 [[texture(5)]],
                         texture2d<float, access::write> dst [[texture(6)]],
                         constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = img.read(uint2(int2(gid) + off[0]));
    float v0 = s.read(uint2(int2(gid) + off[1])).x;
    float m0 = sm0.read(uint2(int2(gid) + off[2])).x;
    float m1 = sm1.read(uint2(int2(gid) + off[3])).x;
    float m2 = sm2.read(uint2(int2(gid) + off[4])).x;
    float m3 = sm3.read(uint2(int2(gid) + off[5])).x;
    float s2 = m3 + nr_soft(v0 - m0, u[0]) + nr_soft(m0 - m1, u[1]) + nr_soft(m1 - m2, u[2]) + nr_soft(m2 - m3, u[3]);
    dst.write(float4(c.rgb * detail_gain(detail_luminance(c.rgb), s2), c.a), gid);
}

// colour stage, step 1: q = rgb / Y, or (1, 1, 1) where Y is at or under the minimum luminance
kernel void noiseRatioTex(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(uint2(int2(gid) + off[0]));
    float y = detail_luminance(c.rgb);
    float3 q = y > detailMinLuminance ? c.rgb / y : float3(1.0f);
    dst.write(float4(q, c.a), gid);
}

// colour stage, step 2: shrink the bands of q per channel, then k = luma(q2); out = Y1 q2 / k, or the input where
// Y1 is at or under the minimum luminance or k is not positive. Inputs: 0 the stage 1 image, 1 q, 2...6 qm0...qm4;
// uniforms t0...t4.
kernel void noiseChromaTex(texture2d<float, access::read> base [[texture(0)]],
                           texture2d<float, access::read> q [[texture(1)]],
                           texture2d<float, access::read> qm0 [[texture(2)]],
                           texture2d<float, access::read> qm1 [[texture(3)]],
                           texture2d<float, access::read> qm2 [[texture(4)]],
                           texture2d<float, access::read> qm3 [[texture(5)]],
                           texture2d<float, access::read> qm4 [[texture(6)]],
                           texture2d<float, access::write> dst [[texture(7)]],
                           constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = base.read(uint2(int2(gid) + off[0]));
    float3 v0 = q.read(uint2(int2(gid) + off[1])).rgb;
    float3 m0 = qm0.read(uint2(int2(gid) + off[2])).rgb;
    float3 m1 = qm1.read(uint2(int2(gid) + off[3])).rgb;
    float3 m2 = qm2.read(uint2(int2(gid) + off[4])).rgb;
    float3 m3 = qm3.read(uint2(int2(gid) + off[5])).rgb;
    float3 m4 = qm4.read(uint2(int2(gid) + off[6])).rgb;
    float3 q2 = m4;
    q2 += float3(nr_soft(v0.x - m0.x, u[0]), nr_soft(v0.y - m0.y, u[0]), nr_soft(v0.z - m0.z, u[0]));
    q2 += float3(nr_soft(m0.x - m1.x, u[1]), nr_soft(m0.y - m1.y, u[1]), nr_soft(m0.z - m1.z, u[1]));
    q2 += float3(nr_soft(m1.x - m2.x, u[2]), nr_soft(m1.y - m2.y, u[2]), nr_soft(m1.z - m2.z, u[2]));
    q2 += float3(nr_soft(m2.x - m3.x, u[3]), nr_soft(m2.y - m3.y, u[3]), nr_soft(m2.z - m3.z, u[3]));
    q2 += float3(nr_soft(m3.x - m4.x, u[4]), nr_soft(m3.y - m4.y, u[4]), nr_soft(m3.z - m4.z, u[4]));
    float y1 = detail_luminance(c.rgb);
    float k = 0.2126f * q2.x + 0.7152f * q2.y + 0.0722f * q2.z;
    if (!(y1 > detailMinLuminance) || !(k > 1.0e-6f)) {
        dst.write(c, gid);
        return;
    }
    dst.write(float4(q2 * (y1 / k), c.a), gid);
}
"""#
}

extension CIBridge {
    /// DarkroomCore.NoiseReduction.apply on the GPU: luminance noise (stage 1) then colour noise (stage 2). Both 0 returns
    /// the image; a stage at 0 is skipped.
    public static func noiseReduction(_ image: CIImage, luma: Double, chroma: Double) throws -> CIImage {
        guard luma != 0 || chroma != 0 else { return image }
        var out = image
        if luma != 0 { out = try noiseLuma(out, luma: luma) }
        if chroma != 0 { out = try noiseChroma(out, chroma: chroma) }
        return out
    }

    private static func noiseLuma(_ image: CIImage, luma: Double) throws -> CIImage {
        let s = try sqrtLuminance(image)
        // smooth[0] = s, smooth[j + 1] = the j-th à trous smoothing; the band j is smooth[j] - smooth[j + 1]
        var smooth = [s]
        for j in 0..<4 { smooth.append(try atrousSmooth(smooth[j], level: j)) }
        let t = (0..<4).map { Float(3 * 0.1 * luma * NoiseReduction.bandNoise[$0]) }
        return try combine([image, s] + smooth[1...4], source: MetalNoiseReduction.source, function: "noiseLumaTex", uniforms: t)
    }

    private static func noiseChroma(_ image: CIImage, chroma: Double) throws -> CIImage {
        let q = try combine([image], source: MetalNoiseReduction.source, function: "noiseRatioTex", uniforms: [])
        // smooth[0] = q, smooth[j + 1] = the j-th smoothing of q; the band j is smooth[j] - smooth[j + 1]
        var smooth = [q]
        for j in 0..<5 { smooth.append(try atrousSmooth(smooth[j], level: j)) }
        let t = (0..<5).map { Float(3 * 0.15 * chroma * NoiseReduction.bandNoise[$0]) }
        return try combine([image, q] + smooth[1...5], source: MetalNoiseReduction.source, function: "noiseChromaTex", uniforms: t)
    }
}
