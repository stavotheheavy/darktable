// Method: the GPU twin of DarkroomCore.ContrastEqualizer: à trous B3 smoothing (Starck and Murtagh, A&A 288, 1994) of the
// square-root luminance, the gained detail bands summed in one per-pixel kernel, and the change given back as a gain
// (MetalDetailCommon, Anscombe 1948).
//
// The five smoothings are chained exactly as Filters.atrous chains them, so the bands are the oracle's. Checked
// against ContrastEqualizer.apply by darkroom-engine-check (E-EQ, E-EQ-seam, E-EQ-fine).

import CoreImage
import Foundation

extension CIBridge {
    /// DarkroomCore.ContrastEqualizer.apply as a Core Image graph. Textures 0...6 are the image, s, and the smoothings
    /// sm0...sm4; `u` holds the three gains 1 + fine, 1 + medium and 1 + coarse.
    public static func contrastEqualizer(_ image: CIImage, fine: Double, medium: Double, coarse: Double) throws -> CIImage {
        let s = try sqrtLuminance(image)
        var smooths: [CIImage] = [], current = s
        for level in 0..<5 {
            current = try atrousSmooth(current, level: level)
            smooths.append(current)
        }
        let kernel = MetalDetailCommon.source + #"""

// s2 = sm4 + gf (s - sm1) + gm (sm1 - sm3) + gc (sm3 - sm4): d0 + d1 = s - sm1, d2 + d3 = sm1 - sm3, d4 = sm3 - sm4
kernel void equalizerTex(texture2d<float, access::read> img [[texture(0)]],
                         texture2d<float, access::read> s [[texture(1)]],
                         texture2d<float, access::read> sm0 [[texture(2)]],
                         texture2d<float, access::read> sm1 [[texture(3)]],
                         texture2d<float, access::read> sm2 [[texture(4)]],
                         texture2d<float, access::read> sm3 [[texture(5)]],
                         texture2d<float, access::read> sm4 [[texture(6)]],
                         texture2d<float, access::write> dst [[texture(7)]],
                         constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = img.read(uint2(int2(gid) + off[0]));
    float s0 = s.read(uint2(int2(gid) + off[1])).x;
    float m1 = sm1.read(uint2(int2(gid) + off[3])).x;
    float m3 = sm3.read(uint2(int2(gid) + off[5])).x;
    float m4 = sm4.read(uint2(int2(gid) + off[6])).x;
    float s2 = m4 + u[0] * (s0 - m1) + u[1] * (m1 - m3) + u[2] * (m3 - m4);
    dst.write(float4(c.rgb * detail_gain(detail_luminance(c.rgb), s2), c.a), gid);
}
"""#
        return try combine([image, s] + smooths, source: kernel, function: "equalizerTex",
                           uniforms: [Float(1 + fine), Float(1 + medium), Float(1 + coarse)])
    }
}
