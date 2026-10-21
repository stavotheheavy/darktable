// Method: triangular-PDF dither at the quantisation step (R. A. Wannamaker, S. P. Lipshitz, J. Vanderkooy, J. N. Wright, "A Theory of
// Nonsubtractive Dither", IEEE Trans. Signal Processing 48(2), 2000): noise of two least significant bits peak to peak, with a triangular
// distribution, added before rounding makes the error independent of the signal, so a smooth shadow gradient no longer breaks into steps.
//
// Applied to the viewport's frame only, in the sRGB-encoded domain where the 8-bit codes live: encode, add up to one code of noise, decode;
// Core Image then encodes and rounds to 8 bits, so the stored code is round(ideal + noise). Black (0) and white (1) are left alone, so a
// clipped or empty area stays clean. The noise is a hash of the pixel's position: the same frame always dithers the same way.
// Checked by darkroom-engine-check E-DIT.
//
// Uniforms: u[0] the noise peak in 8-bit codes (1 is the usual).

import CoreImage
import Foundation

public enum MetalDither {
    public static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    static float dither_hash(uint2 p, uint salt) {
        uint h = p.x * 374761393u + p.y * 668265263u + salt * 2246822519u;
        h = (h ^ (h >> 13)) * 1274126177u;
        h = h ^ (h >> 16);
        return float(h & 0xFFFFFFu) / 16777216.0f;
    }

    static float dither_encode(float v) { return v <= 0.0031308f ? 12.92f * v : 1.055f * pow(v, 1.0f / 2.4f) - 0.055f; }
    static float dither_decode(float e) { return e <= 0.04045f ? e / 12.92f : pow((e + 0.055f) / 1.055f, 2.4f); }

    kernel void ditherTex(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant float *u [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(gid);
        float3 o = c.rgb;
        for (int k = 0; k < 3; k++) {
            float v = o[k];
            if (v > 0.0f && v < 1.0f) {
                // triangular noise in [-1, 1) codes, a separate draw per channel
                float n = (dither_hash(gid, uint(k) * 2u + 1u) + dither_hash(gid, uint(k) * 2u + 2u) - 1.0f) * u[0];
                float e = dither_encode(v) + n / 255.0f;
                o[k] = dither_decode(clamp(e, 0.0f, 1.0f));
            }
        }
        dst.write(float4(o, c.a), gid);
    }
    """#
}

extension CIBridge {
    /// The viewport's last step before 8 bits: triangular dither of `peak` codes in the sRGB-encoded domain (see MetalDither). The image is
    /// in the working space (Rec.2020); the dither is added in linear sRGB primaries, where the 8-bit codes will be made (a per-channel
    /// noise in other primaries would be mixed by the conversion and come out amplified), and the image goes back to the working space,
    /// so the conversion Core Image does on output undoes the first one exactly.
    public static func dither8(_ image: CIImage, peak: Double = 1) throws -> CIImage {
        guard let srgb = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return image }
        let inSRGB = image.matchedFromWorkingSpace(to: srgb) ?? image
        let noisy = try perPixel(inSRGB, source: MetalDither.source, function: "ditherTex", uniforms: [Float(peak)])
        return noisy.matchedToWorkingSpace(from: srgb) ?? noisy
    }
}
