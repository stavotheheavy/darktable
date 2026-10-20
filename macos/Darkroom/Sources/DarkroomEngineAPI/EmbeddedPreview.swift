// Method: Apple ImageIO documentation (CGImageSourceCreateThumbnailAtIndex with kCGImageSourceCreateThumbnailFromImageIfAbsent
// false reads the JPEG the camera embedded and never decodes the RAW).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The camera's own embedded JPEG, read without decoding the RAW: what the library grid and the culling scores are made
/// from, and what the editor shows while the full render runs.
public enum EmbeddedPreview {
    /// The embedded preview scaled to fit `maxSide` on its long edge, EXIF orientation applied, or nil when the file has
    /// none or it is not sRGB (the caller then falls back to a developed render).
    public static func read(path: String, maxSide: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,   // never fall back to a full decode
            kCGImageSourceCreateThumbnailWithTransform: true,        // apply EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        // Read the file mapped and build the source from Data, not from the URL: a URL-backed ImageIO source kept about
        // 0.85 MB per open. Data carries no file name, so the type comes from the extension: without it ImageIO reads a
        // RAW as plain TIFF and finds only the tiny EXIF thumbnail, or none.
        let typeHint = UTType(filenameExtension: url.pathExtension)?.identifier
        let sourceOptions = typeHint.map { [kCGImageSourceTypeIdentifierHint: $0] as CFDictionary }
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              cg.colorSpace?.name == CGColorSpace.sRGB
        else { return nil }
        return cg
    }
}
