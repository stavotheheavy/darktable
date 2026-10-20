import CoreGraphics
import CoreImage
import DarkroomEngineAPI
import Foundation
import ImageIO
import Metal
import Synchronization
import UniformTypeIdentifiers

/// The clean engine: Apple's RAW decoder through Core Image. Written from Apple's Core
/// Image documentation only; it does not use darktable code (see THIRD-PARTY.md).
///
/// M0 scope: decode, viewport render, region render, one-shot render and export. Edits
/// are not implemented yet, so a non-empty stack is refused rather than silently ignored.
///
/// Scales follow `Engine`: `sessionInfo().processedWidth` is the working frame, and a
/// scale of 1.0 is that frame's size. Region coordinates are in the scaled frame's
/// pixels, with the origin at the top left.
public actor CIEngine: PhotoEngine {
    private struct Session {
        let url: URL
        let raw: CIRAWFilter
        let native: CGSize
        /// Native pixels to working-frame pixels for the maxSide this session was opened at.
        let fit: Double
        let maxSide: Int
    }

    private var context: CIContext?
    private var session: Session?

    /// Set from any thread by `cancelRender()`; checked between decode and render.
    private let cancelFlag = Mutex(false)

    public init() {}

    public func start(prefix: URL, configDir: URL, cacheDir: URL) async throws {
        // prefix, configDir and cacheDir belong to darktable; the clean engine needs none.
        guard context == nil else { return }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EngineError("no Metal device for Core Image")
        }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: true])
    }

    public func shutdown() async {
        session = nil
        context = nil
    }

    // MARK: session

    public func openSession(path: String, maxSide: Int) async throws {
        guard context != nil else { throw EngineError("engine not started") }
        session = nil
        session = try Self.makeSession(path: path, maxSide: maxSide)
    }

    public func closeSession() async {
        session = nil
    }

    public nonisolated func cancelRender() {
        cancelFlag.withLock { $0 = true }
    }

    public func sessionRender(stack: [StackEntry], scale: Double) async throws -> RenderedFrame {
        let s = try openedSession()
        try Self.refuseEdits(stack)
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        let image = try decode(s, scale: s.fit * scale)
        return try frame(image, crop: nil, since: started)
    }

    public func sessionRenderRegion(stack: [StackEntry], scale: Double, x: Int, y: Int,
                                    width: Int, height: Int) async throws -> RenderedFrame {
        let s = try openedSession()
        try Self.refuseEdits(stack)
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        let image = try decode(s, scale: s.fit * scale)
        let ext = image.extent.integral
        // Core Image's origin is bottom left; the region is given top left.
        let wanted = CGRect(x: ext.minX + CGFloat(x), y: ext.maxY - CGFloat(y) - CGFloat(height),
                            width: CGFloat(width), height: CGFloat(height))
        let crop = wanted.intersection(ext)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1 else {
            throw EngineError("region lies outside the image")
        }
        return try frame(image, crop: crop, since: started)
    }

    /// The decoder the open image uses: RAW 9 where Apple supports the camera.
    public func decoderVersion() async -> String? {
        session.map { $0.raw.decoderVersion.rawValue }
    }

    /// The camera's embedded JPEG, read by ImageIO without decoding the RAW. Decoding it
    /// is what makes the first frame fast; the full render replaces it when ready.
    /// Returns nil when the file has no embedded preview or it is not sRGB, so the UI
    /// simply waits for the full render.
    public func sessionPreview() async throws -> RenderedFrame? {
        let s = try openedSession()
        let started = ContinuousClock.now
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,   // never fall back to a full decode
            kCGImageSourceCreateThumbnailWithTransform: true,        // apply EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: s.maxSide,
        ]
        // Read the file mapped and build the source from Data, not from the URL: a URL-backed
        // ImageIO source kept about 0.85 MB per open, so RSS grew with every photo opened.
        // Data carries no file name, so the type comes from the extension: without it ImageIO
        // reads a RAW as plain TIFF and finds only the tiny EXIF thumbnail, or none.
        let typeHint = UTType(filenameExtension: s.url.pathExtension)?.identifier
        let sourceOptions = typeHint.map { [kCGImageSourceTypeIdentifierHint: $0] as CFDictionary }
        guard let data = try? Data(contentsOf: s.url, options: .alwaysMapped),
              let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              cg.colorSpace?.name == CGColorSpace.sRGB
        else { return nil }
        let elapsed = started.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        return RenderedFrame(image: cg, width: cg.width, height: cg.height, milliseconds: ms)
    }

    public func sessionInfo() async -> SessionInfo? {
        guard let s = session else { return nil }
        return SessionInfo(
            processedWidth: Int((s.native.width * s.fit).rounded()),
            processedHeight: Int((s.native.height * s.fit).rounded()),
            workWidth: Int(s.native.width), workHeight: Int(s.native.height))
    }

    public func sessionModules() async throws -> [ModuleInfo] {
        _ = try openedSession()
        return []   // modules arrive with M1
    }

    public func exportRender(path: String, maxSide: Int, stack: [StackEntry]) async throws -> RenderedFrame {
        try Self.refuseEdits(stack)
        return try await render(path: path, maxSide: maxSide, stack: stack)
    }

    // MARK: one-shot

    public func render(path: String, maxSide: Int, stack: [StackEntry]) async throws -> RenderedFrame {
        guard context != nil else { throw EngineError("engine not started") }
        try Self.refuseEdits(stack)
        let s = try Self.makeSession(path: path, maxSide: maxSide)
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        let image = try decode(s, scale: s.fit)
        return try frame(image, crop: nil, since: started)
    }

    // MARK: modules (none in M0)

    public func moduleNames() async throws -> [String] { [] }

    public func schema(for operation: String) async throws -> ModuleSchema {
        throw EngineError("the clean engine has no module \(operation) yet")
    }

    public func defaultValue(operation: String, field: String) async throws -> Double? { nil }

    // MARK: helpers

    private func openedSession() throws -> Session {
        guard context != nil else { throw EngineError("engine not started") }
        guard let session else { throw EngineError("no image is open") }
        return session
    }

    private static func refuseEdits(_ stack: [StackEntry]) throws {
        guard stack.isEmpty else {
            throw EngineError("the clean engine does not apply edits yet (M1)")
        }
    }

    private static func makeSession(path: String, maxSide: Int) throws -> Session {
        let url = URL(fileURLWithPath: path)
        guard let raw = CIRAWFilter(imageURL: url) else {
            throw EngineError("cannot decode \(url.lastPathComponent)")
        }
        let native = raw.nativeSize
        let long = max(native.width, native.height)
        let fit = long > 0 ? min(1, Double(maxSide) / Double(long)) : 1
        return Session(url: url, raw: raw, native: native, fit: fit, maxSide: maxSide)
    }

    /// Decode at `scale` of the native size. Decoding small is what makes open fast:
    /// the RAW decoder does the downscale, not a later resample.
    private func decode(_ s: Session, scale: Double) throws -> CIImage {
        s.raw.scaleFactor = Float(scale)
        guard let image = s.raw.outputImage else {
            throw EngineError("decode failed")
        }
        return image
    }

    private func frame(_ image: CIImage, crop: CGRect?, since started: ContinuousClock.Instant) throws -> RenderedFrame {
        guard let context else { throw EngineError("engine not started") }
        if cancelFlag.withLock({ $0 }) { throw RenderCanceled() }
        let rect = crop ?? image.extent.integral
        guard let cg = context.createCGImage(image, from: rect, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw EngineError("could not render the frame")
        }
        let elapsed = started.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        return RenderedFrame(image: cg, width: cg.width, height: cg.height, milliseconds: ms)
    }
}
