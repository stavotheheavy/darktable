import AppKit
import Metal
import ScreenCaptureKit

/// A display-level look at the window for the test rig: ScreenCaptureKit captures it in HDR (half-float pixels, values above SDR white
/// kept), which a CGWindowListCreateImage capture cannot do (it clips at 1.0). Reports how much of the window is above SDR white and writes a
/// map in which those pixels are painted, so the headroom can be seen without an HDR viewer. Needs the screen-recording permission.
extension Rig {
    func hdrCapture(prefix: String, region: CGRect?) async -> [String: Any] {
        guard let win = window else { return ["error": "no window"] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(win.windowNumber) }) else { return ["error": "window not shareable"] }
            let config = SCStreamConfiguration()
            config.captureDynamicRange = .hdrLocalDisplay
            config.pixelFormat = kCVPixelFormatType_64RGBAHalf
            config.showsCursor = false
            let scale = win.backingScaleFactor
            config.width = Int(target.frame.width * scale)
            config.height = Int(target.frame.height * scale)
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
            guard let data = image.dataProvider?.data as Data?, image.bitsPerComponent == 16, image.bitsPerPixel == 64 else {
                return ["error": "capture is not 16-bit float RGBA", "bits": image.bitsPerComponent, "bpp": image.bitsPerPixel]
            }
            let w = image.width, h = image.height, rowBytes = image.bytesPerRow
            let spaceName = (image.colorSpace?.name as String?) ?? "unknown"
            let linear = spaceName.localizedCaseInsensitiveContains("linear")
            // the photo area (window points, top left) or the whole window
            let rect = region.map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) }
                ?? CGRect(x: 0, y: 0, width: w, height: h)
            let x0 = max(0, Int(rect.minX)), x1 = min(w, Int(rect.maxX)), y0 = max(0, Int(rect.minY)), y1 = min(h, Int(rect.maxY))
            var maxV: Float = 0, above = 0, total = 0
            var map = [UInt8](repeating: 0, count: w * h * 4)
            func encode(_ v: Float) -> UInt8 {
                let c = min(max(v, 0), 1)
                let e = linear ? (c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) : c
                return UInt8((e * 255).rounded())
            }
            data.withUnsafeBytes { raw in
                for y in 0..<h {
                    for x in 0..<w {
                        let o = y * rowBytes + x * 8
                        let r = Float(Float16(bitPattern: raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)))
                        let g = Float(Float16(bitPattern: raw.loadUnaligned(fromByteOffset: o + 2, as: UInt16.self)))
                        let b = Float(Float16(bitPattern: raw.loadUnaligned(fromByteOffset: o + 4, as: UInt16.self)))
                        let peak = max(r, g, b)
                        let inside = x >= x0 && x < x1 && y >= y0 && y < y1
                        if inside, peak.isFinite { maxV = max(maxV, peak); total += 1; if peak > 1.002 { above += 1 } }
                        let i = (y * w + x) * 4
                        if peak > 1.002, inside {
                            // above SDR white: painted cyan, brighter the more headroom the pixel uses
                            let k = UInt8(min(255.0, 120.0 + 135.0 * Double(min(peak - 1, 1))))
                            map[i] = 0; map[i + 1] = k; map[i + 2] = k; map[i + 3] = 255
                        } else {
                            map[i] = encode(r); map[i + 1] = encode(g); map[i + 2] = encode(b); map[i + 3] = 255
                        }
                    }
                }
            }
            var written = ""
            let pngData: Data? = map.withUnsafeMutableBytes { buf -> Data? in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let cg = ctx.makeImage() else { return nil }
                return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }
            if let pngData { try pngData.write(to: URL(fileURLWithPath: prefix + ".hdrmap.png")); written = prefix + ".hdrmap.png" }
            return ["ok": true, "colorSpace": spaceName, "width": w, "height": h, "maxValue": Double(maxV),
                    "pixelsAboveSDRWhitePct": total > 0 ? Double(above) / Double(total) * 100 : 0, "pixelsMeasured": total, "map": written]
        } catch {
            return ["error": "\(error)"]
        }
    }
}


extension Rig {
    /// The presented texture itself, which is what the display is handed: texels above SDR white are painted cyan (brighter the more headroom
    /// they use), the rest shown as they are, so where the HDR preview uses headroom can be seen in an ordinary PNG.
    func frameMap(out: String, gamut: Bool = false) -> [String: Any] {
        guard let f = model.frameTexture else { return ["error": "the canvas is not presenting a texture"] }
        let w = f.width, h = f.height
        var half = [UInt16](repeating: 0, count: w * h * 4)
        f.texture.getBytes(&half, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var above = 0, maxV: Float = 0, sumAbove = 0.0
        func enc(_ v: Float) -> UInt8 {
            let c = min(max(v, 0), 1)
            return UInt8(((c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255).rounded())
        }
        for i in 0..<(w * h) {
            let r = Float(Float16(bitPattern: half[i * 4])), g = Float(Float16(bitPattern: half[i * 4 + 1])), b = Float(Float16(bitPattern: half[i * 4 + 2]))
            let peak = max(r, g, b)
            if peak.isFinite { maxV = max(maxV, peak) }
            if gamut {
                // linear Display P3 to linear sRGB: a component outside 0...peak means a colour sRGB cannot show; painted magenta, the rest dimmed grey
                let sr = 1.2249401 * r - 0.2249404 * g, sg = -0.0420569 * r + 1.0420571 * g, sb = -0.0196376 * r - 0.0786361 * g + 1.0982735 * b
                let lo = min(sr, sg, sb)
                if lo < -0.003 {
                    above += 1; sumAbove += Double(-lo)
                    let k = UInt8(min(255.0, 140.0 + 115.0 * Double(min(-lo * 8, 1))))
                    px[i * 4] = k; px[i * 4 + 1] = 0; px[i * 4 + 2] = k
                } else {
                    let l = enc(0.2126 * sr + 0.7152 * sg + 0.0722 * sb) / 2
                    px[i * 4] = l; px[i * 4 + 1] = l; px[i * 4 + 2] = l
                }
                continue
            }
            if peak > 1.002 {
                above += 1; sumAbove += Double(peak)
                let k = UInt8(min(255.0, 110.0 + 145.0 * Double(min(peak - 1, 1))))
                px[i * 4] = 0; px[i * 4 + 1] = k; px[i * 4 + 2] = k
            } else {
                px[i * 4] = enc(r); px[i * 4 + 1] = enc(g); px[i * 4 + 2] = enc(b)
            }
        }
        let pngData: Data? = px.withUnsafeMutableBytes { buf -> Data? in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let cg = ctx.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }
        guard let png = pngData else { return ["error": "could not write the map"] }
        try? png.write(to: URL(fileURLWithPath: out))
        return ["ok": true, "width": w, "height": h, "peak": f.peak, "maxValue": Double(maxV),
                "texelsAboveSDRWhitePct": Double(above) / Double(w * h) * 100, "meanAbove": above > 0 ? sumAbove / Double(above) : 0, "map": out]
    }
}
