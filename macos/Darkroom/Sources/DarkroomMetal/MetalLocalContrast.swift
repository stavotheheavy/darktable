// Method: the GPU twin of DarkroomCore.LocalContrast: the self-guided guided filter (He, Sun and Tang, ECCV 2010) on the
// square root of luminance (Anscombe 1948), then the boost s + detail (s - base) given back as a gain on all channels.

import CoreImage
import DarkroomCore
import Foundation

extension CIBridge {
    private static let localContrastSource = MetalDetailCommon.source + #"""

    // (c, s, base) per pixel: s' = s + detail (s - base), then the gain Y'/Y on the RGB pixel (DetailCommon.applying)
    kernel void localcontrastTex(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::read> sTex [[texture(1)]],
                                 texture2d<float, access::read> baseTex [[texture(2)]],
                                 texture2d<float, access::write> dst [[texture(3)]],
                                 constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        float s = sTex.read(uint2(int2(gid) + off[1])).x;
        float b = baseTex.read(uint2(int2(gid) + off[2])).x;
        float s2 = s + u[0] * (s - b);
        dst.write(float4(c.rgb * detail_gain(detail_luminance(c.rgb), s2), c.a), gid);
    }
    """#

    /// DarkroomCore.LocalContrast.apply: the image with its square-root luminance boosted by `detail` over the
    /// guided base at `radius` pixels (rounded, at least 1). Detail 0 returns the image.
    public static func localContrast(_ image: CIImage, detail: Double, radius: Double) throws -> CIImage {
        guard detail != 0 else { return image }
        let s = try sqrtLuminance(image)
        let base = try guided(s, radius: max(1, Int(radius.rounded())), eps: LocalContrast.eps)
        return try combine([image, s, base], source: localContrastSource, function: "localcontrastTex", uniforms: [Float(detail)])
    }
}
