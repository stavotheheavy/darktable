import CoreGraphics
import DarkroomCore
import DarkroomEngineAPI
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a mask layer is: painted with the brush, or found by Vision.
public enum MaskLayerKind: String, Codable, Sendable, CaseIterable {
    case brush, subject, person, face, eyes, lips, animal, object

    public init(_ vision: VisionMasks.Kind) { self = MaskLayerKind(rawValue: vision.rawValue) ?? .subject }
    public var vision: VisionMasks.Kind? { VisionMasks.Kind(rawValue: rawValue) }
    public var title: String { vision?.title ?? rawValue }
}

/// A painted or detected mask of one photo. A module's blend refers to it by `mask_raster = "<id>.<revision>"`: a brush layer's
/// revision is how many of its strokes count (an undo step is a smaller number), a detected layer's is always 0.
public struct MaskLayer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: MaskLayerKind
    /// A brush layer's strokes, oldest first. Append-only apart from the cut a new stroke makes after an undo.
    public var strokes: [BrushStroke] = []
    /// A detected layer's picture, a PNG in the photo's masks folder.
    public var picture: String?
}

/// The pictures of detected layers, next to the photo: `<raw>.darkroom.masks/<layer id>.png`, 8-bit grey.
enum MaskFiles {
    static func directory(for raw: String) -> URL { URL(fileURLWithPath: raw + ".darkroom.masks") }

    static func write(_ pixels: [UInt8], width: Int, height: Int, name: String, for raw: String) throws {
        let dir = directory(for: raw)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func read(name: String, for raw: String) -> (width: Int, height: Int, pixels: [UInt8])? {
        let url = directory(for: raw).appendingPathComponent(name)
        guard name == (name as NSString).lastPathComponent,   // a file in the folder, never a path out of it
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0, image.width * image.height <= 64_000_000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? (image.width, image.height, pixels) : nil
    }
}
