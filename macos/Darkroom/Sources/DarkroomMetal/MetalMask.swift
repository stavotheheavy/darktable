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

    /// u[0] kind, u[1] invert (0/1), u[2...9] the kind's parameters, u[10] the camera orientation 0...7. geom = (x0, y0, width, height) of the output in the
    /// whole frame, top-left origin; a pixel's frame position is (x0 + gid.x + 0.5, y0 + gid.y + 0.5).
    static let dispatch = #"""
// where a point of a size image lands for an EXIF-style orientation 0...7 (DarkroomCore.Orientation.map)
static float2 mask_orient(int o, float2 p, float2 size) {
    float w = size.x, h = size.y;
    if (o == 1) { return float2(p.x, h - p.y); }
    if (o == 2) { return float2(w - p.x, p.y); }
    if (o == 3) { return float2(w - p.x, h - p.y); }
    if (o == 4) { return float2(p.y, p.x); }
    if (o == 5) { return float2(h - p.y, p.x); }
    if (o == 6) { return float2(p.y, w - p.x); }
    if (o == 7) { return float2(h - p.y, w - p.x); }
    return p;
}

static float mask_alpha(constant float *u, float sx, float sy, float sW, float sH, float3 rgb) {
    constant float *p = u + 2;
    int orient = int(u[10] + 0.5f);
    float2 pos = mask_orient(orient, float2(sx, sy), float2(sW, sH));
    float2 sz = (orient >= 4) ? float2(sH, sW) : float2(sW, sH);
    float x = pos.x, y = pos.y, W = sz.x, H = sz.y;
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
        u.append(Float(spec.orientation.rawValue))   // u[10]
        return u
    }
}

/// The resampled raster mattes (a raster kind's weights for one picture size and orientation), kept so a render that only
/// moves a slider does not resample a million pixels again.
enum RasterMatteCache {
    nonisolated(unsafe) private static var store: [String: Data] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    private static let lock = NSLock()

    static func plane(for spec: MaskSpec, width: Int, height: Int) -> Data {
        let key = "\(spec.raster?.id ?? "-")|\(width)x\(height)|\(spec.orientation.rawValue)|\(spec.invert ? 1 : 0)"
        lock.lock()
        if let hit = store[key] { lock.unlock(); return hit }
        lock.unlock()
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let a = Mask.alpha(spec, x: Double(x) + 0.5, y: Double(y) + 0.5, width: Double(width), height: Double(height), rgb: .zero)
                bytes[y * width + x] = UInt8(min(max((a * 255).rounded(), 0), 255))
            }
        }
        let data = Data(bytes)
        lock.lock()
        store[key] = data; order.append(key)
        while order.count > 8 { store[order.removeFirst()] = nil }
        lock.unlock()
        return data
    }
}

extension CIBridge {
    /// The finished mask for `image` (the module's input) as (a, a, a, 1): Mask.plane on the GPU.
    public static func localMask(_ image: CIImage, spec: MaskSpec) throws -> CIImage {
        if spec.kind == 5 { return try rasterMatte(image, spec: spec) }
        let raw = try combine([image], source: MetalMask.source, function: "maskAlphaTex", uniforms: MetalMask.uniforms(spec))
        guard spec.refineRadius > 0 else { return raw }
        return try guided(raw, guide: image, radius: spec.refineRadius, eps: Mask.refineEps)
    }

    /// A raster kind's matte: the picture sampled where each pixel of `image` sits in the upright photo (DarkroomCore's own
    /// sampler, so engine and oracle agree), as an 8-bit grey image, then refined to the photo's edges like any mask.
    private static func rasterMatte(_ image: CIImage, spec: MaskSpec) throws -> CIImage {
        let ext = image.extent.integral
        let w = Int(ext.width), h = Int(ext.height)
        guard w > 0, h > 0 else { throw CIBridgeError.badArguments }
        let data = RasterMatteCache.plane(for: spec, width: w, height: h)
        let grey = CIImage(bitmapData: data, bytesPerRow: w, size: CGSize(width: w, height: h), format: .L8, colorSpace: nil)
            .transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
        guard spec.refineRadius > 0 else { return grey }
        return try guided(grey, guide: image, radius: spec.refineRadius, eps: Mask.refineEps)
    }

    /// Mask.blend on the GPU.
    public static func blendMasked(before: CIImage, after: CIImage, mask: CIImage, opacity: Double) throws -> CIImage {
        try combine([before, after, mask], source: MetalMask.source, function: "maskBlendTex", uniforms: [Float(opacity)])
    }
}
