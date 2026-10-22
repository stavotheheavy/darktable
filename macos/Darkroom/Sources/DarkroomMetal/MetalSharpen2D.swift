// Method: the GPU twin of DarkroomCore.Sharpen2D: s = sqrt(Y) and the gain Y'/Y from MetalDetailCommon (Anscombe 1948),
// the same cumulative B3 à trous blur on s as the oracle (Starck and Murtagh, A&A 288, 1994), then s' = s + amount (s - base).

import CoreImage
import DarkroomCore

extension CIBridge {
    /// DarkroomCore.Sharpen2D.apply as an image. `amount` 0 or less returns the image untouched.
    public static func sharpen2D(_ image: CIImage, amount: Double, radius: Double) throws -> CIImage {
        guard amount > 0 else { return image }
        let s = try sqrtLuminance(image)
        let c = Sharpen2D.cascades(radius: radius)
        var levels: [CIImage] = [s]   // levels[k + 1] is cascade k
        if c.hi >= 0 { for j in 0...c.hi { levels.append(try atrousSmooth(levels.last!, level: j)) } }
        return try combine([image, s, levels[c.lo + 1], levels[c.hi + 1]], source: MetalDetailCommon.source + sharpen2DKernel,
                           function: "sharpen2dTex", uniforms: [Float(amount), Float(c.weight)])
    }
}

/// Inputs: the image (0), s (1) and the two neighbouring bases (2, 3), all (x, x, x) for s; output at 4. u[0] is the amount, u[1] the weight of base 3 over base 2.
private let sharpen2DKernel = #"""

kernel void sharpen2dTex(texture2d<float, access::read> img [[texture(0)]],
                         texture2d<float, access::read> s [[texture(1)]],
                         texture2d<float, access::read> baseLo [[texture(2)]],
                         texture2d<float, access::read> baseHi [[texture(3)]],
                         texture2d<float, access::write> dst [[texture(4)]],
                         constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = img.read(uint2(int2(gid) + off[0]));
    float sv = s.read(uint2(int2(gid) + off[1])).x;
    float bl = baseLo.read(uint2(int2(gid) + off[2])).x;
    float bh = baseHi.read(uint2(int2(gid) + off[3])).x;
    float bv = bl + u[1] * (bh - bl);
    float s2 = sv + u[0] * (sv - bv);
    dst.write(float4(c.rgb * detail_gain(detail_luminance(c.rgb), s2), c.a), gid);
}
"""#
