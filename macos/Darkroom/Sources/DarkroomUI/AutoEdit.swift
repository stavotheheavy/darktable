import CoreGraphics
import DarkroomEngineAPI
import Foundation

/// What Auto edit decides from a look at the photo, in Simple's units (Light is percent of two stops, the rest percent).
public struct AutoEditPlan: Equatable, Sendable {
    public var lightStops = 0.0
    public var shadows = 0.0, highlights = 0.0, contrast = 0.0, color = 0.0
    /// The face the exposure was set for, if one was found.
    public var forFace = false

    /// One line for the status bar.
    public var summary: String {
        var parts: [String] = []
        if abs(lightStops) >= 0.05 { parts.append(String(format: "%+.1f stops%@", lightStops, forFace ? " for the face" : "")) }
        if highlights != 0 { parts.append(String(format: "highlights %+.0f", highlights)) }
        if shadows != 0 { parts.append(String(format: "shadows %+.0f", shadows)) }
        if contrast != 0 { parts.append(String(format: "contrast %+.0f", contrast)) }
        return parts.isEmpty ? "white balance" : "white balance, " + parts.joined(separator: ", ")
    }
}

/// Auto edit's judgement: a few numbers read off a small display-referred picture, turned into modest moves of Simple's controls.
/// It aims for a picture an editor would call a fair start, never a finished look: every move is capped, and a photo that is
/// already well exposed is left alone.
public enum AutoEdit {
    /// `luma`: display-referred brightness 0...1, row-major. `faceLuma`: the mean brightness of a face in it, when there is one.
    public static func plan(luma: [Float], faceLuma: Double?) -> AutoEditPlan {
        guard luma.count >= 16 else { return AutoEditPlan() }
        var bins = [Int](repeating: 0, count: 256)
        for v in luma { bins[min(255, max(0, Int(v * 255)))] += 1 }
        let n = Double(luma.count)
        func percentile(_ p: Double) -> Double {
            var run = 0
            for (i, c) in bins.enumerated() { run += c; if Double(run) >= p * n { return Double(i) / 255 } }
            return 1
        }
        let median = percentile(0.5), low = percentile(0.005), high = percentile(0.995)
        let clipped = Double(bins[251...].reduce(0, +)) / n          // 0.985 and up
        let crushed = Double(bins[..<10].reduce(0, +)) / n           // under 0.04

        var plan = AutoEditPlan()
        // exposure: the middle (or the face) toward a comfortable display brightness; display brightness goes as light^(1/2.2)
        let measured = max(faceLuma ?? median, 0.02), target = faceLuma != nil ? 0.52 : 0.44
        var stops = log2(pow(target / measured, 2.2)) * 0.7
        // do not push the brightest part into clipping to get there
        if stops > 0, high > 0.8 { stops = min(stops, max(2.2 * log2(1 / max(high, 0.01)) + 0.5, 0)) }
        stops = min(max(stops, -1.5), 1.5)
        if abs(stops) >= 0.1 { plan.lightStops = (stops * 10).rounded() / 10; plan.forFace = faceLuma != nil }
        if clipped > 0.01 { plan.highlights = -min(60, (clipped * 1500).rounded()) }
        if crushed > 0.08 { plan.shadows = min(40, (crushed * 150).rounded()) }
        if high - low < 0.8 { plan.contrast = min(25, ((0.8 - (high - low)) * 60).rounded()) }
        plan.color = 12
        return plan
    }

    /// Display brightness of an 8-bit RGBA picture, 0...1 (Rec. 709 weights on the encoded values).
    public static func luma(of image: CGImage) -> (values: [Float], width: Int, height: Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var values = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(bytes[i * 4]), g = Float(bytes[i * 4 + 1]), b = Float(bytes[i * 4 + 2])
            values[i] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }
        return (values, w, h)
    }

    /// The mean of `luma` where `mask` is lit (above half), the mask being any size; nil when it lights under 0.5% of the picture.
    public static func meanLuma(_ luma: [Float], width: Int, height: Int, under mask: VisionMasks.Picture) -> Double? {
        var sum = 0.0, count = 0
        for y in 0..<height {
            let my = min(mask.height - 1, y * mask.height / height)
            for x in 0..<width where mask.pixels[my * mask.width + min(mask.width - 1, x * mask.width / width)] > 127 {
                sum += Double(luma[y * width + x]); count += 1
            }
        }
        return Double(count) >= 0.005 * Double(width * height) ? sum / Double(count) : nil
    }
}
