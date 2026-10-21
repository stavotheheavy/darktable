// Method: OkLab LCh (Björn Ottosson, "A perceptual color space for image processing", 2020); the same eight-band smoothstep blend over hue as ColorZones in DarkroomCore, with the band centres taken from it at run time.

import DarkroomCore
import Foundation

/// The Metal function for `ColorZones`. Uniforms: `u[0...7]` the hue sliders, `u[8...15]` saturation, `u[16...23]` lightness (each -1...1).
/// A function only, no kernels: it is compiled into the fused pass.
public enum MetalColorZones {
    public static let function: String = {
        let centres = ColorZones.centresDegrees.map { String(format: "%.9ff", $0 * Double.pi / 180) }.joined(separator: ", ")
        return """

        constant float cz_centres[8] = { \(centres) };

        static float3 colorzones_apply(float3 rgb, constant float *u) {
            float3 lab = cc_to_oklab(rgb);
            float chroma = length(lab.yz);
            float w = cc_smoothstep(\(String(format: "%.9ff", ColorZones.chromaFloor)), \(String(format: "%.9ff", ColorZones.chromaFull)), chroma);
            if (!(w > 0.0f) || !isfinite(chroma)) { return rgb; }
            const float tau = 6.283185307f;
            float h = atan2(lab.z, lab.y);
            if (h < 0.0f) { h += tau; }
            int i = 7;
            if (h >= cz_centres[0]) {
                for (int k = 0; k < 7; k++) { if (h >= cz_centres[k] && h < cz_centres[k + 1]) { i = k; } }
            } else {
                h += tau;
            }
            int j = (i + 1) % 8;
            float cj = cz_centres[j] + (j == 0 ? tau : 0.0f);
            float t = cc_smoothstep(0.0f, 1.0f, (h - cz_centres[i]) / (cj - cz_centres[i]));
            float dh = (u[i] * (1.0f - t) + u[j] * t) * \(String(format: "%.9ff", ColorZones.hueRangeDegrees * Double.pi / 180)) * w;
            float k2 = max(1.0f + (u[8 + i] * (1.0f - t) + u[8 + j] * t) * w, 0.0f);
            float dl = (u[16 + i] * (1.0f - t) + u[16 + j] * t) * \(String(format: "%.9ff", ColorZones.lightnessRange)) * w;
            float hue = h + dh;
            float c2 = chroma * k2;
            return cc_from_oklab(float3(max(lab.x + dl, 0.0f), c2 * cos(hue), c2 * sin(hue)));
        }
        """
    }()

    /// Standalone kernels for darkroom-metal-check (the fused pass uses `function` alone).
    public static let source = MetalColorCommon.source + function + #"""

kernel void colorzonesTex(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant float *u [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(colorzones_apply(c.rgb, u), c.a), gid);
}

kernel void colorzonesBuf(device const float4 *src [[buffer(0)]],
                          device float4 *dst [[buffer(1)]],
                          constant float *u [[buffer(2)]],
                          uint i [[thread_position_in_grid]]) {
    float4 c = src[i];
    dst[i] = float4(colorzones_apply(c.rgb, u), c.a);
}
"""#
}
