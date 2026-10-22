// Method: Apple's Vision framework, on the Mac, with no network: VNGenerateForegroundInstanceMaskRequest (the subject cut-out
// behind "lift subject"), VNGeneratePersonSegmentationRequest (people, hair and clothes included) and
// VNDetectFaceLandmarksRequest (faces and their parts), VNRecognizeAnimalsRequest (cats and dogs, a box each), then the landmark outlines filled into a grey picture. Convex hull:
// Andrew's monotone chain (A. M. Andrew, "Another efficient algorithm for convex hulls in two dimensions", 1979).
// Every picture is of the image it was given, row 0 on top, 0...255: give it the UPRIGHT picture.

import CoreGraphics
import CoreVideo
import Foundation
import Vision

public enum VisionMasks {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case subject, person, face, eyes, lips, animal, object

        public var title: String {
            switch self {
            case .subject: "subject"
            case .person: "person"
            case .face: "face"
            case .eyes: "eyes"
            case .lips: "lips"
            case .animal: "animal"
            case .object: "objects"
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
        case .animal: return try animals(image)
        case .object: return try objects(image)
        }
    }

    // MARK: animals and objects

    /// Vision has no recogniser for things in general. What it has: the foreground cut-out split into separate instances, cats
    /// and dogs with a box each, and people as a segmentation. So an *animal* is the foreground instance(s) inside a
    /// cat or dog box (the box as a soft ellipse when no instance lines up), and *objects* are the foreground instances that
    /// are neither a person nor an animal.
    private static func animals(_ image: CGImage) throws -> Picture? {
        let boxes = try animalBoxes(image)
        guard !boxes.isEmpty else { return nil }
        let w = image.width, h = image.height
        if let cut = try foregroundInstances(image) {
            let labels = cut.labelsInside(boxes: boxes, minShare: 0.5)
            if !labels.isEmpty, let p = try cut.picture(of: labels, width: w, height: h), p.coverage > 0.0005 { return p }
        }
        // nothing lifted lines up with the animal: the box as a soft ellipse
        return ellipses(in: boxes, width: w, height: h)
    }

    private static func objects(_ image: CGImage) throws -> Picture? {
        guard let cut = try foregroundInstances(image) else { return nil }
        let w = image.width, h = image.height
        var skip = cut.labelsInside(boxes: try animalBoxes(image), minShare: 0.5)
        if let people = try person(image) { skip.formUnion(cut.labelsOver(people, minShare: 0.5)) }
        let keep = cut.labels.subtracting(skip)
        guard !keep.isEmpty, let p = try cut.picture(of: keep, width: w, height: h), p.coverage > 0.0005 else { return nil }
        return p
    }

    /// Cat and dog boxes, normalised to the picture, origin at the top left.
    private static func animalBoxes(_ image: CGImage) throws -> [CGRect] {
        let request = VNRecognizeAnimalsRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).filter { $0.confidence >= 0.5 }.map {
            CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height)
        }
    }

    private static func ellipses(in boxes: [CGRect], width w: Int, height h: Int) -> Picture? {
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            for b in boxes {
                // CoreGraphics' origin is bottom left; the boxes are top left
                ctx.fillEllipse(in: CGRect(x: b.minX * Double(w), y: (1 - b.maxY) * Double(h), width: b.width * Double(w), height: b.height * Double(h)))
            }
            return true
        }
        guard ok else { return nil }
        let p = Picture(width: w, height: h, pixels: bytes)
        return p.coverage > 0 ? p : nil
    }

    /// The foreground cut-out as separate instances: a label per pixel (0 background), at the model's own resolution.
    struct Instances {
        let observation: VNInstanceMaskObservation
        let handler: VNImageRequestHandler
        let labels: Set<Int>
        let labelMap: [UInt8], mapWidth: Int, mapHeight: Int

        /// Instances with at least `minShare` of their pixels inside one of `boxes` (normalised, top left origin).
        func labelsInside(boxes: [CGRect], minShare: Double) -> Set<Int> {
            Set(labels.filter { l in
                var total = 0, inside = 0
                for y in 0..<mapHeight { for x in 0..<mapWidth where labelMap[y * mapWidth + x] == UInt8(l) {
                    total += 1
                    let p = CGPoint(x: (Double(x) + 0.5) / Double(mapWidth), y: (Double(y) + 0.5) / Double(mapHeight))
                    if boxes.contains(where: { $0.contains(p) }) { inside += 1 }
                } }
                return total > 0 && Double(inside) / Double(total) >= minShare
            })
        }

        /// Instances with at least `minShare` of their pixels over a lit part (above half) of `mask`.
        func labelsOver(_ mask: Picture, minShare: Double) -> Set<Int> {
            Set(labels.filter { l in
                var total = 0, over = 0
                for y in 0..<mapHeight { for x in 0..<mapWidth where labelMap[y * mapWidth + x] == UInt8(l) {
                    total += 1
                    let mx = min(mask.width - 1, x * mask.width / mapWidth), my = min(mask.height - 1, y * mask.height / mapHeight)
                    if mask.pixels[my * mask.width + mx] > 127 { over += 1 }
                } }
                return total > 0 && Double(over) / Double(total) >= minShare
            })
        }

        func picture(of keep: Set<Int>, width: Int, height: Int) throws -> Picture? {
            let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(keep), from: handler)
            return VisionMasks.grey(from: buffer, width: width, height: height)
        }
    }

    private static func foregroundInstances(_ image: CGImage) throws -> Instances? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let o = request.results?.first, !o.allInstances.isEmpty else { return nil }
        let buffer = o.instanceMask
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        var map = [UInt8](repeating: 0, count: bw * bh)
        for y in 0..<bh { for x in 0..<bw { map[y * bw + x] = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)[x] } }
        return Instances(observation: o, handler: handler, labels: Set(o.allInstances), labelMap: map, mapWidth: bw, mapHeight: bh)
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
