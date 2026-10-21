import CoreGraphics
import DarkroomEngineAPI
import Metal

/// A synthetic card for checking the display path by eye, with no screen capture: it goes through the same Metal layer as a photo (rgba16Float,
/// extended linear Display P3). Top: nine bars from SDR white to twice SDR white; with the HDR preview off the layer clips them all to the same
/// white, with it on a display that has headroom shows them stepping brighter up to what it can give. Middle: the six Display P3 primaries and
/// secondaries, each above the same colour clipped into sRGB; on a wide-gamut display the upper patch is visibly more saturated. Bottom: a plain
/// grey ramp, so a banding or tone problem shows apart from the other two.
enum TestCard {
    static let width = 1600, height = 900

    /// Display P3 to linear sRGB (the inverse of the sRGB to P3 matrix); a component outside 0...1 is a colour sRGB cannot show.
    private static func p3ToSRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(1.2249401 * c.x - 0.2249404 * c.y,
              -0.0420569 * c.x + 1.0420571 * c.y,
              -0.0196376 * c.x - 0.0786361 * c.y + 1.0982735 * c.z)
    }

    private static func srgbToP3(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(0.8224621 * c.x + 0.1775380 * c.y,
              0.0331941 * c.x + 0.9668058 * c.y,
              0.0170827 * c.x + 0.0723974 * c.y + 0.9105199 * c.z)
    }

    static func rgb(x: Int, y: Int) -> SIMD3<Float> {
        let third = height / 3
        if y < third {
            let bar = min(x * 9 / width, 8)
            let gap = (x * 9 % width) < 12 || y < 14 || y > third - 14   // dark gutters so the bars read as separate
            return gap ? SIMD3(repeating: 0.05) : SIMD3(repeating: 1 + Float(bar) * 0.125)
        }
        if y < 2 * third {
            let cell = min(x * 6 / width, 5)
            let gap = (x * 6 % width) < 12 || y < third + 14 || y > 2 * third - 14 || abs(y - (third + third / 2)) < 4
            if gap { return SIMD3(repeating: 0.05) }
            let p3: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 0)]
            let c = p3[cell]
            if y < third + third / 2 { return c }
            let s = p3ToSRGB(c)
            return srgbToP3(SIMD3(min(max(s.x, 0), 1), min(max(s.y, 0), 1), min(max(s.z, 0), 1)))
        }
        return SIMD3(repeating: Float(x) / Float(width - 1))
    }

    /// The card as a frame the canvas can present. `peak` is the headroom the layer is asked for (1 leaves it SDR).
    static func frame(device: MTLDevice, peak: Double) -> PresentedFrame? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = rgb(x: x, y: y), i = (y * width + x) * 4
                pixels[i] = Float16(c.x); pixels[i + 1] = Float16(c.y); pixels[i + 2] = Float16(c.z)
            }
        }
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        // the small 8-bit copy the scopes read: the same card, clipped to SDR
        let tw = 160, th = 90
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        for y in 0..<th {
            for x in 0..<tw {
                let c = rgb(x: x * width / tw, y: y * height / th)
                ctx.setFillColor(red: CGFloat(min(c.x, 1)), green: CGFloat(min(c.y, 1)), blue: CGFloat(min(c.z, 1)), alpha: 1)
                ctx.fill(CGRect(x: x, y: th - 1 - y, width: 1, height: 1))
            }
        }
        guard let thumb = ctx.makeImage() else { return nil }
        return PresentedFrame(texture: texture, width: width, height: height, milliseconds: 0, thumbnail: thumb, peak: peak)
    }
}
