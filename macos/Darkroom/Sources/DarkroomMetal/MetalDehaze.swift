// Method: the GPU twin of DarkroomCore.Dehaze: dark channel prior (He, Sun and Tang, CVPR 2009) with the transmission
// refined by the guided filter (ECCV 2010) against the photo's square-root luminance, recovery J = (I - A) / max(t, 0.1) + A.

import CoreImage
import DarkroomCore
import Foundation

public enum MetalDehaze {
    public static let source = MetalDetailCommon.source + #"""

// (max(min(r, g, b), 0) / A, same in three channels, alpha carried); u[0] = 1 / A
kernel void dehazeMinTex(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(uint2(int2(gid) + off[0]));
    float m = min(max(min(c.r, min(c.g, c.b)), 0.0f) * u[0], 1.0f);
    dst.write(float4(m, m, m, c.a), gid);
}

// raw transmission 1 - strength * dark; u[0] = strength
kernel void dehazeRawTex(texture2d<float, access::read> dark [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float d = dark.read(uint2(int2(gid) + off[0])).x;
    float t = 1.0f - u[0] * d;
    dst.write(float4(t, t, t, 1.0f), gid);
}

// J = (I - A) / max(t, 0.1) + A ; u[0] = A, u[1] = the minimum transmission
kernel void dehazeOutTex(texture2d<float, access::read> img [[texture(0)]],
                         texture2d<float, access::read> trans [[texture(1)]],
                         texture2d<float, access::write> dst [[texture(2)]],
                         constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = img.read(uint2(int2(gid) + off[0]));
    float t = max(trans.read(uint2(int2(gid) + off[1])).x, u[1]);
    float3 air = float3(u[0]);
    float3 hazy = min(c.rgb, air);   // light brighter than the airlight is not haze and passes through
    dst.write(float4(max((hazy - air) / t + air + (c.rgb - hazy), 0.0f), c.a), gid);
}
"""#
}

extension CIBridge {
    /// DarkroomCore.Dehaze.apply on the GPU.
    public static func dehaze(_ image: CIImage, strength: Double, radius: Double, airlight: Double) throws -> CIImage {
        guard strength > 0 else { return image }
        let r = Int(min(max(radius.rounded(), 1), 100))
        let a = max(airlight, 1e-6)
        let mins = try combine([image], source: MetalDehaze.source, function: "dehazeMinTex", uniforms: [Float(1 / a)])
        let dark = try minFilter(mins, radius: r)
        let raw = try combine([dark], source: MetalDehaze.source, function: "dehazeRawTex", uniforms: [Float(min(strength, 1))])
        let t = try guided(raw, guide: try sqrtLuminance(image), radius: Dehaze.refineRadius(patch: r), eps: Dehaze.refineEps)
        return try combine([image, t], source: MetalDehaze.source, function: "dehazeOutTex",
                           uniforms: [Float(a), Float(Dehaze.minTransmission)])
    }
}
