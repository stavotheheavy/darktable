// Method: the GPU twin of DarkroomCore.Blur, Soften and Mosaic: three box means (CIBridge.boxMean, the same separable pass Bloom uses), a mix
// of the picture toward its blur, and a gather of each block's centre pixel.

import CoreImage
import DarkroomCore
import Foundation

extension CIBridge {
    private static let softenSource = MetalColorCommon.source + #"""

    kernel void softenMixTex(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::read> blur [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 c = src.read(uint2(int2(gid) + off[0]));
        float4 b = blur.read(uint2(int2(gid) + off[1]));
        dst.write(float4(c.rgb + u[0] * (b.rgb - c.rgb), c.a), gid);
    }
    """#

    private static let mosaicSource = MetalColorCommon.source + #"""

    kernel void mosaicTex(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                          constant float4 *geom [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int s = max(int(u[0] + 0.5f), 1);
        int ax = int(geom[0].x + 0.5f) + int(gid.x), ay = int(geom[0].y + 0.5f) + int(gid.y);
        int cx = min((ax / s) * s + s / 2, int(geom[0].z + 0.5f) - 1);
        int cy = min((ay / s) * s + s / 2, int(geom[0].w + 0.5f) - 1);
        dst.write(src.read(uint2(int2(gid) + off[0] + int2(cx - ax, cy - ay))), gid);
    }
    """#

    /// DarkroomCore.Blur.apply: three box means of `radius` pixels. Radius 0 returns the image.
    public static func blur(_ image: CIImage, radius: Int) throws -> CIImage {
        guard radius > 0 else { return image }
        var out = image
        for _ in 0..<Blur.passes { out = try boxMean(out, radius: radius) }
        return out
    }

    /// DarkroomCore.Soften.apply: the image mixed `strength` of the way toward its blur.
    public static func soften(_ image: CIImage, strength: Double, radius: Int) throws -> CIImage {
        guard strength != 0, radius > 0 else { return image }
        return try combine([image, try blur(image, radius: radius)], source: softenSource, function: "softenMixTex", uniforms: [Float(strength)])
    }

    /// DarkroomCore.Mosaic.apply: every `block` x `block` square from the frame's top-left shows its centre pixel.
    public static func mosaic(_ image: CIImage, block: Int) throws -> CIImage {
        guard block > 1 else { return image }
        let ext = image.extent
        // a pixel reads at most one block away, so the input is asked for that much more
        let out = try PerPixelManyProcessor.apply(withExtent: ext, inputs: [image.clampedToExtent()],
                                                  arguments: ["function": "mosaicTex", "uniforms": [Float(block)], "source": mosaicSource,
                                                              "reach": block,
                                                              "extent": [Double(ext.minX), Double(ext.minY), Double(ext.width), Double(ext.height)]])
        return out.cropped(to: ext)
    }
}
