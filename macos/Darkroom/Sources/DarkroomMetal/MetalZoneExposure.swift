// Method: DarkroomCore.ZoneExposure (He, Sun and Tang, "Guided Image Filtering", ECCV 2010, for the base; Durand and Dorsey,
// SIGGRAPH 2002, for the base and detail split). Three steps on the GPU: the log luminance of the picture as a plane, that
// plane smoothed edge-aware by the guided filter already in this module's neighbour (CIBridge.guided), then a gain read
// from the smoothed plane and multiplied onto all three channels.
// Checked by darkroom-engine-check E-ZE (against the oracle, across tile seams, at two scales).
//
// Uniforms of zoneGainTex: u[0...9] the ten zone changes in EV (zone -7 first).

import CoreImage
import DarkroomCore
import Foundation

public enum MetalZoneExposure {
    public static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    kernel void zoneLogTex(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float3 c = src.read(uint2(int2(gid) + off[0])).rgb;
        float y = max(dot(c, float3(0.2126f, 0.7152f, 0.0722f)), 1e-6f);
        float z = log2(y / 0.18f);
        dst.write(float4(z, z, z, 1.0f), gid);
    }

    // out = image * 2^gain(base), the gain a raised-cosine blend of the two zones the base falls between
    kernel void zoneGainTex(texture2d<float, access::read> img [[texture(0)]],
                            texture2d<float, access::read> base [[texture(1)]],
                            texture2d<float, access::write> dst [[texture(2)]],
                            constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = img.read(uint2(int2(gid) + off[0]));
        float b = base.read(uint2(int2(gid) + off[1])).r;
        b = isfinite(b) ? clamp(b, -7.0f, 2.0f) : 0.0f;
        int k = min(int(floor(b)), 1);
        float f = b - float(k);
        float upper = 0.5f * (1.0f - cos(3.14159265358979f * f));
        float g = u[k + 7] * (1.0f - upper) + u[k + 8] * upper;
        dst.write(float4(c.rgb * exp2(g), c.a), gid);
    }
    """#
}

extension CIBridge {
    /// DarkroomCore.ZoneExposure.apply on the GPU. `evs` are the ten zone changes in EV after the semantic controls.
    public static func zoneExposure(_ image: CIImage, evs: [Double], radius: Int) throws -> CIImage {
        guard evs.count == 10, evs.contains(where: { $0 != 0 }) else { return image }
        let z = try combine([image], source: MetalZoneExposure.source, function: "zoneLogTex", uniforms: [0])
        let base = try guided(z, radius: min(max(radius, 1), ZoneExposure.maxRadius), eps: ZoneExposure.eps)
        return try combine([image, base], source: MetalZoneExposure.source, function: "zoneGainTex", uniforms: evs.map { Float($0) })
    }
}
