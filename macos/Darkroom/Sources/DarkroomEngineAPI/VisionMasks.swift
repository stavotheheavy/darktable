// Method: Apple's Vision framework, on the Mac, with no network: VNGenerateForegroundInstanceMaskRequest (the subject cut-out
// behind "lift subject"), VNGeneratePersonSegmentationRequest (people, hair and clothes included) and
// VNDetectFaceLandmarksRequest (faces and their parts), then the landmark outlines filled into a grey picture. Convex hull:
// Andrew's monotone chain (A. M. Andrew, "Another efficient algorithm for convex hulls in two dimensions", 1979).
// Every picture is of the image it was given, row 0 on top, 0...255: give it the UPRIGHT picture.

import CoreGraphics
import CoreVideo
import Foundation
import Vision

public enum VisionMasks {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case subject, person, face, eyes, lips

        public var title: String {
            switch self {
            case .subject: "subject"
            case .person: "person"
            case .face: "face"
            case .eyes: "eyes"
            case .lips: "lips"
            }
        }
    }

    public struct Picture: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let pixels: [UInt8]
        /// The share of the picture the mask covers, 0...1.
        public var coverage: Double { Double(pixels.reduce(0) { $0 + Int($1) }) / (255.0 * Double(max(pixels.count, 1))) }
    }

    /// The mask of `kind` for `image`, or nil when Vision finds nothing of that kind in it.
    public static func detect(_ kind: Kind, in image: CGImage) throws -> Picture? {
        switch kind {
        case .subject: return try subject(image)
        case .person: return try person(image)
        case .face, .eyes, .lips: return try faceParts(kind, image)
        }
    }

    // MARK: subject and person

    private static func subject(_ image: CGImage) throws -> Picture? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        return grey(from: buffer, width: image.width, height: image.height)
    }

    private static func person(_ image: CGImage) throws -> Picture? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer,
              let picture = grey(from: buffer, width: image.width, height: image.height), picture.coverage > 0.0005 else { return nil }
        return picture
    }

    /// A Vision mask buffer (8-bit or 32-bit float, one component) as a grey picture, resampled to `width` by `height` when its
    /// own size differs (bilinear).
    static func grey(from buffer: CVPixelBuffer, width: Int, height: Int) -> Picture? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        func value(_ x: Int, _ y: Int) -> Double {
            let row = base.advanced(by: min(max(y, 0), bh - 1) * stride)
            switch format {
            case kCVPixelFormatType_OneComponent32Float:
                let v = Double(row.assumingMemoryBound(to: Float.self)[min(max(x, 0), bw - 1)])
                return v.isFinite ? min(max(v, 0), 1) : 0
            case kCVPixelFormatType_OneComponent8: return Double(row.assumingMemoryBound(to: UInt8.self)[min(max(x, 0), bw - 1)]) / 255
            case kCVPixelFormatType_OneComponent16Half:
                let v = Double(row.assumingMemoryBound(to: Float16.self)[min(max(x, 0), bw - 1)])
                return v.isFinite ? min(max(v, 0), 1) : 0
            default: return 0
            }
        }
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = (Double(y) + 0.5) * Double(bh) / Double(height) - 0.5
            let y0 = Int(sy.rounded(.down)), fy = sy - Double(y0)
            for x in 0..<width {
                let sx = (Double(x) + 0.5) * Double(bw) / Double(width) - 0.5
                let x0 = Int(sx.rounded(.down)), fx = sx - Double(x0)
                let top = value(x0, y0) * (1 - fx) + value(x0 + 1, y0) * fx
                let bottom = value(x0, y0 + 1) * (1 - fx) + value(x0 + 1, y0 + 1) * fx
                out[y * width + x] = UInt8(min(max(((top * (1 - fy) + bottom * fy) * 255).rounded(), 0), 255))
            }
        }
        return Picture(width: width, height: height, pixels: out)
    }

    // MARK: face, eyes, lips

    private static func faceParts(_ kind: Kind, _ image: CGImage) throws -> Picture? {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let faces = request.results, !faces.isEmpty else { return nil }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setShouldAntialias(true)
            ctx.setFillColor(gray: 1, alpha: 1)
            func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] { region?.pointsInImage(imageSize: CGSize(width: w, height: h)) ?? [] }
            func fill(_ polygon: [CGPoint], grow: CGFloat) {
                guard polygon.count >= 3 else { return }
                let c = CGPoint(x: polygon.map(\.x).reduce(0, +) / CGFloat(polygon.count), y: polygon.map(\.y).reduce(0, +) / CGFloat(polygon.count))
                let grown = polygon.map { CGPoint(x: c.x + ($0.x - c.x) * grow, y: c.y + ($0.y - c.y) * grow) }
                ctx.beginPath(); ctx.addLines(between: grown); ctx.closePath(); ctx.fillPath()
            }
            for face in faces {
                guard let lm = face.landmarks else { continue }
                switch kind {
                case .face:
                    fill(hull(points(lm.faceContour) + points(lm.leftEyebrow) + points(lm.rightEyebrow)), grow: 1.06)
                case .eyes:
                    fill(points(lm.leftEye), grow: 1.4); fill(points(lm.rightEye), grow: 1.4)
                case .lips:
                    fill(points(lm.outerLips), grow: 1.1)
                default: break
                }
            }
            return true
        }
        guard drawn else { return nil }
        let picture = Picture(width: w, height: h, pixels: bytes)
        return picture.coverage > 0 ? picture : nil
    }

    /// The convex hull of `points` (counter-clockwise).
    static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return p }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for q in p { while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }; lower.append(q) }
        for q in p.reversed() { while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }; upper.append(q) }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }
}
