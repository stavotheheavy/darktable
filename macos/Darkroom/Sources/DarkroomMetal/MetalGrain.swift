// Method: the GPU twins of DarkroomCore.Grain (lattice value noise from a hash of the pixel position, added to the encoded value with a midtone
// weight) and DarkroomCore.Highpass (the encoded value minus its three-box blur, on mid-grey).

import CoreImage
import DarkroomCore
import Foundation

extension CIBridge {
    private static let grainSource = MetalColorCommon.source + MetalBaseCurve.function + #"""

    static float gr_lattice(int x, int y, uint seed) {
        uint h = uint(x) * 374761393u + uint(y) * 668265263u + seed * 2246822519u;
        h = (h ^ (h >> 13)) * 1274126177u;
        h ^= h >> 16;
        return float(h) / 4294967295.0f * 2.0f - 1.0f;
    }

    static float gr_noise(float x, float y, float size, uint seed) {
        float s = max(size, 0.5f);
        float u = x / s, v = y / s;
        float iu = floor(u), iv = floor(v);
        float fu = cc_smoothstep(0.0f, 1.0f, u - iu), fv = cc_smoothstep(0.0f, 1.0f, v - iv);
        int x0 = int(iu), y0 = int(iv);
        float a = gr_lattice(x0, y0, seed), b = gr_lattice(x0 + 1, y0, seed);
        float c = gr_lattice(x0, y0 + 1, seed), d = gr_lattice(x0 + 1, y0 + 1, seed);
        return (a * (1.0f - fu) + b * fu) * (1.0f - fv) + (c * (1.0f - fu) + d * fu) * fv;
    }

    static float gr_channel(float v, float amount) {
        float e = bc_encode(v);
        return bc_decode(clamp(e + amount * 4.0f * e * (1.0f - e), 0.0f, 1.0f));
    }

    kernel void grainTex(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                         constant float4 *geom [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        int ax = int(geom[0].x + 0.5f) + int(gid.x), ay = int(geom[0].y + 0.5f) + int(gid.y);
        float amount = \#(String(format: "%.9ff", Grain.amplitude)) * u[0] * gr_noise(float(ax), float(ay), u[1], uint(u[2] + 0.5f));
        dst.write(float4(gr_channel(c.r, amount), gr_channel(c.g, amount), gr_channel(c.b, amount), c.a), gid);
    }
    """#

    private static let highpassSource = MetalColorCommon.source + MetalBaseCurve.function + #"""

    kernel void hpEncodeTex(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        dst.write(float4(bc_encode(c.r), bc_encode(c.g), bc_encode(c.b), c.a), gid);
    }

    kernel void hpMixTex(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::read> blur [[texture(1)]],
                         texture2d<float, access::write> dst [[texture(2)]],
                         constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        float3 b = blur.read(uint2(int2(gid) + off[1])).rgb;
        float3 e = float3(bc_encode(c.r), bc_encode(c.g), bc_encode(c.b));
        float3 o = clamp(0.5f + u[0] * (e - b), 0.0f, 1.0f);
        dst.write(float4(bc_decode(o.r), bc_decode(o.g), bc_decode(o.b), c.a), gid);
    }
    """#

    /// DarkroomCore.Grain.apply over the whole frame; `size` is the lattice spacing in pixels (already scaled).
    public static func grain(_ image: CIImage, strength: Double, size: Double, seed: UInt32) throws -> CIImage {
        guard strength != 0 else { return image }
        return try combine([image], source: grainSource, function: "grainTex", uniforms: [Float(strength), Float(size), Float(seed)])
    }

    /// DarkroomCore.Highpass.apply: the encoded value minus its blur of `radius` per pass (0 is no blur), on mid-grey.
    public static func highpass(_ image: CIImage, strength: Double, radius: Int) throws -> CIImage {
        let encoded = try combine([image], source: highpassSource, function: "hpEncodeTex", uniforms: [0])
        return try combine([image, try blur(encoded, radius: radius)], source: highpassSource, function: "hpMixTex", uniforms: [Float(strength)])
    }
}
