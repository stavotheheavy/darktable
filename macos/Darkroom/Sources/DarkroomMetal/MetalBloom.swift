// Method: the GPU twin of DarkroomCore.Bloom: the highlights through a soft luminance knee, three box means, and the result added to the
// picture times the strength.

import CoreImage
import DarkroomCore
import Foundation

extension CIBridge {
    private static let bloomSource = MetalColorCommon.source + #"""

    kernel void bloomBrightTex(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        dst.write(float4(c.rgb * cc_smoothstep(u[0], u[1], cc_luminance(c.rgb)), c.a), gid);
    }

    kernel void bloomAddTex(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::read> glow [[texture(1)]],
                            texture2d<float, access::write> dst [[texture(2)]],
                            constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        float4 g = glow.read(uint2(int2(gid) + off[1]));
        dst.write(float4(c.rgb + u[0] * g.rgb, c.a), gid);
    }
    """#

    /// DarkroomCore.Bloom.apply: the image with its blurred highlights added, `strength` times, over a glow of `radius` per pass.
    /// Strength 0 returns the image.
    public static func bloom(_ image: CIImage, strength: Double, radius: Double) throws -> CIImage {
        guard strength != 0 else { return image }
        var glow = try combine([image], source: bloomSource, function: "bloomBrightTex",
                               uniforms: [Float(Bloom.kneeLow), Float(Bloom.kneeHigh)])
        for _ in 0..<Bloom.passes { glow = try boxMean(glow, radius: radius) }
        return try combine([image, glow], source: bloomSource, function: "bloomAddTex", uniforms: [Float(strength)])
    }
}
