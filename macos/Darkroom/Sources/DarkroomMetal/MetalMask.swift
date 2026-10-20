// Method: the GPU twin of DarkroomCore.Mask: a per-pixel weight from position or colour (kinds in MetalMaskGradient,
// MetalMaskEllipse, MetalMaskLuminance, MetalMaskColour), optional inversion, optional refinement by the guided filter
// against the photo (He, Sun and Tang, ECCV 2010), and the matte mix of a module's output over its input (Porter and
// Duff, SIGGRAPH 1984).

import CoreImage
import DarkroomCore
import Foundation

public enum MetalMask {
    static let prelude = #"""
static float mask_ramp(float e0, float e1, float x) {
    if (!(e1 > e0)) { return x >= e0 ? 1.0f : 0.0f; }
    float t = clamp((x - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}
"""#

    /// u[0] kind, u[1] invert (0/1), u[2...9] the kind's parameters. geom = (x0, y0, width, height) of the output in the
    /// whole frame, top-left origin; a pixel's frame position is (x0 + gid.x + 0.5, y0 + gid.y + 0.5).
    static let dispatch = #"""
static float mask_alpha(constant float *u, float x, float y, float W, float H, float3 rgb) {
    constant float *p = u + 2;
    int kind = int(u[0] + 0.5f);
    float a = 1.0f;
    if (kind == 1) { a = mask_gradient(p, x, y, W, H); }
    else if (kind == 2) { a = mask_ellipse(p, x, y, W, H); }
    else if (kind == 3) { a = mask_luminance(p, rgb); }
    else if (kind == 4) { a = mask_colour(p, rgb); }
    return u[1] > 0.5f ? 1.0f - a : a;
}

kernel void maskAlphaTex(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                         constant float4 *geom [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(uint2(int2(gid) + off[0]));
    float a = mask_alpha(u, geom[0].x + float(gid.x) + 0.5f, geom[0].y + float(gid.y) + 0.5f, geom[0].z, geom[0].w, c.rgb);
    dst.write(float4(a, a, a, 1.0f), gid);
}

// before (0), after (1), mask (2): before + (after - before) * (opacity * mask)
kernel void maskBlendTex(texture2d<float, access::read> before [[texture(0)]],
                         texture2d<float, access::read> after [[texture(1)]],
                         texture2d<float, access::read> mask [[texture(2)]],
                         texture2d<float, access::write> dst [[texture(3)]],
                         constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 b = before.read(uint2(int2(gid) + off[0]));
    float4 a = after.read(uint2(int2(gid) + off[1]));
    float m = mask.read(uint2(int2(gid) + off[2])).x;
    dst.write(float4(b.rgb + (a.rgb - b.rgb) * (u[0] * m), b.a), gid);
}
"""#

    public static let source = MetalColorCommon.source + prelude + MetalMaskGradient.source + MetalMaskEllipse.source
        + MetalMaskLuminance.source + MetalMaskColour.source + dispatch

    static func uniforms(_ spec: MaskSpec) -> [Float] {
        var u: [Float] = [Float(spec.kind), spec.invert ? 1 : 0]
        u += spec.p.prefix(8).map { Float($0) }
        while u.count < 10 { u.append(0) }
        return u
    }
}

extension CIBridge {
    /// The finished mask for `image` (the module's input) as (a, a, a, 1): Mask.plane on the GPU.
    public static func localMask(_ image: CIImage, spec: MaskSpec) throws -> CIImage {
        let raw = try combine([image], source: MetalMask.source, function: "maskAlphaTex", uniforms: MetalMask.uniforms(spec))
        guard spec.refineRadius > 0 else { return raw }
        return try guided(raw, guide: image, radius: spec.refineRadius, eps: Mask.refineEps)
    }

    /// Mask.blend on the GPU.
    public static func blendMasked(before: CIImage, after: CIImage, mask: CIImage, opacity: Double) throws -> CIImage {
        try combine([before, after, mask], source: MetalMask.source, function: "maskBlendTex", uniforms: [Float(opacity)])
    }
}
