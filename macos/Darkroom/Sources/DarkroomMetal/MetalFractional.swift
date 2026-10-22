// Method: the GPU twin of DarkroomCore.FractionalWindow: the blend of a module's whole-radius results n and n + 1 by the fraction, the window 0 being the picture itself.

import CoreImage
import DarkroomCore
import Foundation

extension CIBridge {
    private static let fractionalSource = MetalColorCommon.source + #"""

    kernel void fractionalCopyTex(texture2d<float, access::read> a [[texture(0)]],
                                  texture2d<float, access::write> dst [[texture(1)]],
                                  constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        dst.write(a.read(uint2(int2(gid) + off[0])), gid);
    }

    kernel void fractionalMixTex(texture2d<float, access::read> a [[texture(0)]],
                                 texture2d<float, access::read> b [[texture(1)]],
                                 texture2d<float, access::write> dst [[texture(2)]],
                                 constant float *u [[buffer(0)]], constant int2 *off [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 x = a.read(uint2(int2(gid) + off[0]));
        float4 y = b.read(uint2(int2(gid) + off[1]));
        dst.write(float4(x.rgb + u[0] * (y.rgb - x.rgb), x.a), gid);
    }
    """#

    /// DarkroomCore.FractionalWindow.apply: `run(source, k)` renders the module at the whole radius k (k >= 1) from `source`, which is `image`. A whole radius runs once.
    /// The second run reads its own copy of the image: two blurs of one image in one kernel get aliased by Core Image (a module that blurs inside, skin smooth and chroma denoise,
    /// came out as noise), and a copy through a kernel of its own is a different image to it.
    public static func fractionalWindow(_ image: CIImage, radius r: Double, _ run: (CIImage, Int) throws -> CIImage) throws -> CIImage {
        let (n, f) = FractionalWindow.split(r)
        let a = n >= 1 ? try run(image, n) : image
        guard f > 1e-12 else { return a }
        let copy = try combine([image], source: fractionalSource, function: "fractionalCopyTex", uniforms: [])
        let b = try run(copy, n + 1)
        return try combine([a, b], source: fractionalSource, function: "fractionalMixTex", uniforms: [Float(f)])
    }
}
