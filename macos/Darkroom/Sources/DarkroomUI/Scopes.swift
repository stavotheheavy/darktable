import CoreGraphics
import Foundation

/// Measurements of the displayed frame: histogram, waveform, vectorscope, clipping.
/// Computed from the 8-bit B,G,R,x frame the engine hands back, which is exactly what
/// is on screen.
public struct ScopeData: Sendable {
    public static let bins = 256
    public static let waveRows = 128
    public static let vectorSize = 96

    /// 4 x 256, each normalized to its own peak: red, green, blue, luma.
    public var histogram: [[Float]]
    /// bins columns x waveRows rows of luma density, 0...1, row 0 = darkest.
    public var waveform: [Float]
    /// vectorSize x vectorSize chroma density, 0...1, centre = neutral.
    public var vectorscope: [Float]
    public var shadowClip: Double      // fraction of pixels with a channel at 0
    public var highlightClip: Double   // fraction with a channel at 255

    public static func measure(_ image: CGImage, stride step: Int = 2) -> ScopeData? {
        guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
        let w = image.width, h = image.height, rowBytes = image.bytesPerRow
        guard w > 0, h > 0 else { return nil }

        var hist = [[Float]](repeating: [Float](repeating: 0, count: bins), count: 4)
        var wave = [Float](repeating: 0, count: bins * waveRows)
        var vec = [Float](repeating: 0, count: vectorSize * vectorSize)
        var lo = 0, hi = 0, n = 0

        let st = max(1, step)
        for y in Swift.stride(from: 0, to: h, by: st) {
            let row = y * rowBytes
            for x in Swift.stride(from: 0, to: w, by: st) {
                let o = row + x * 4
                let b = Int(p[o]), g = Int(p[o + 1]), r = Int(p[o + 2])
                let l = (2126 * r + 7152 * g + 722 * b) / 10000
                hist[0][r] += 1; hist[1][g] += 1; hist[2][b] += 1; hist[3][l] += 1

                let col = min(bins - 1, x * bins / w)
                wave[col * waveRows + min(waveRows - 1, l * waveRows / 256)] += 1

                // BT.709 chroma, -0.5...0.5 on each axis
                let fy = Double(l)
                let u = (Double(b) - fy) * 0.5389 / 255.0
                let v = (Double(r) - fy) * 0.6350 / 255.0
                let ui = min(vectorSize - 1, max(0, Int((u + 0.5) * Double(vectorSize))))
                let vi = min(vectorSize - 1, max(0, Int((0.5 - v) * Double(vectorSize))))
                vec[vi * vectorSize + ui] += 1

                if r == 0 || g == 0 || b == 0 { lo += 1 }
                if r == 255 || g == 255 || b == 255 { hi += 1 }
                n += 1
            }
        }
        guard n > 0 else { return nil }

        for c in 0..<4 {
            // a log curve keeps a tall spike from flattening everything else
            let peak = hist[c].max() ?? 1
            hist[c] = hist[c].map { peak > 0 ? Float(log1p(Double($0)) / log1p(Double(peak))) : 0 }
        }
        func normalize(_ a: inout [Float]) {
            let peak = a.max() ?? 1
            guard peak > 0 else { return }
            let lp = log1p(Double(peak))
            for i in a.indices { a[i] = Float(log1p(Double(a[i])) / lp) }
        }
        normalize(&wave)
        normalize(&vec)

        return ScopeData(histogram: hist, waveform: wave, vectorscope: vec,
                         shadowClip: Double(lo) / Double(n), highlightClip: Double(hi) / Double(n))
    }
}

/// Renders a density grid into a CGImage so Canvas can draw it as one bitmap.
enum ScopeBitmap {
    static func image(width: Int, height: Int, flipVertical: Bool,
                      density: [Float], red: Double, green: Double, blue: Double) -> CGImage? {
        guard density.count == width * height else { return nil }
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let sy = flipVertical ? height - 1 - y : y
            for x in 0..<width {
                let d = Double(density[sy * width + x])
                let o = (y * width + x) * 4
                let a = min(1.0, d * 1.15)
                px[o] = UInt8(red * a * 255)
                px[o + 1] = UInt8(green * a * 255)
                px[o + 2] = UInt8(blue * a * 255)
                px[o + 3] = UInt8(a * 255)
            }
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        return px.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: info) else { return nil }
            return ctx.makeImage()
        }
    }

    /// Waveform: x = image column, y = luma (bright at the top).
    static func waveform(_ s: ScopeData) -> CGImage? {
        // stored column-major (col * rows + row); the grid for the bitmap is row-major
        let w = ScopeData.bins, h = ScopeData.waveRows
        var grid = [Float](repeating: 0, count: w * h)
        for c in 0..<w { for r in 0..<h { grid[r * w + c] = s.waveform[c * h + r] } }
        return image(width: w, height: h, flipVertical: true, density: grid,
                     red: 0.43, green: 0.9, blue: 0.63)
    }

    static func vectorscope(_ s: ScopeData) -> CGImage? {
        image(width: ScopeData.vectorSize, height: ScopeData.vectorSize, flipVertical: false,
              density: s.vectorscope, red: 1.0, green: 0.78, blue: 0.45)
    }
}
