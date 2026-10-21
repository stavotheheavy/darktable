// Method: the GPU twin of DarkroomCore.HdrTone: the zone path's smooth edge-aware base of the log luminance (CIBridge.zoneBase), then a gain
// 2^(-amount * clamp(base, -7, 3)) multiplied onto all three channels.

import CoreImage
import DarkroomCore
import Foundation

extension CIBridge {
    private static let hdrToneSource = MetalColorCommon.source + #"""

    kernel void hdrGainTex(texture2d<float, access::read> img [[texture(0)]],
                           texture2d<float, access::read> base [[texture(1)]],
                           texture2d<float, access::write> dst [[texture(2)]],
                           constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = img.read(uint2(int2(gid) + off[0]));
        float b = base.read(uint2(int2(gid) + off[1])).r;
        b = isfinite(b) ? clamp(b, -7.0f, 3.0f) : 0.0f;
        dst.write(float4(c.rgb * exp2(-u[0] * b), c.a), gid);
    }
    """#

    /// DarkroomCore.HdrTone.apply on the GPU; `radius` is the guided filter's radius in pixels.
    public static func hdrTone(_ image: CIImage, amount: Double, radius: Int) throws -> CIImage {
        guard amount != 0 else { return image }
        return try combine([image, try zoneBase(image, radius: radius)], source: hdrToneSource, function: "hdrGainTex", uniforms: [Float(amount)])
    }
}
