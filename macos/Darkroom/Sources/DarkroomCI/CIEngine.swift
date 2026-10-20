import CoreGraphics
import CoreImage
import DarkroomCore
import DarkroomEngineAPI
import DarkroomMetal
import Foundation
import ImageIO
import Metal
import Synchronization
import UniformTypeIdentifiers

/// The clean engine: Apple's RAW decoder through Core Image. Written from Apple's Core
/// Image documentation only; it does not use darktable code (see THIRD-PARTY.md).
///
/// Decode, viewport render, region render, one-shot render, export, and the modules in
/// `CIModule.all` applied as a stack. An operation outside the catalogue is refused.
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
        /// The decoder's own tone settings, restored when no scene-referred module is on.
        let boost: Float
        let localToneMap: Float
        /// The camera's orientation. The decoder runs in sensor orientation (`native` is the sensor's size)
        /// and geometry applies this as the default flip, as darktable orders it.
        let camera: Orientation

        /// The decoded size at scale 1 (the working frame), in sensor orientation.
        var sensorFrame: CGSize { CGSize(width: (native.width * fit).rounded(), height: (native.height * fit).rounded()) }
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
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        let image = try edited(try decode(s, scale: s.fit * scale, stack: stack), stack, camera: s.camera)
        return try frame(image, crop: nil, since: started)
    }

    public func sessionRenderRegion(stack: [StackEntry], scale: Double, x: Int, y: Int,
                                    width: Int, height: Int) async throws -> RenderedFrame {
        let s = try openedSession()
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        let image = try edited(try decode(s, scale: s.fit * scale, stack: stack), stack, camera: s.camera)
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

    /// The output size at scale 1 (the working frame) for `stack`: geometry only, nothing is rendered.
    public func sessionOutputSize(stack: [StackEntry]) async throws -> (width: Int, height: Int)? {
        let s = try openedSession()
        return CIGeometry.pixelSize(try CIGeometry.spec(stack, camera: s.camera), input: s.sensorFrame)
    }

    public func sessionInfo() async -> SessionInfo? {
        guard let s = session else { return nil }
        // the as-shot frame: `native` is the sensor's, which made portrait photos report as landscape
        let frame = CIGeometry.pixelSize(GeometrySpec(orientation: s.camera), input: s.sensorFrame)
        let swaps = s.camera.swapsAxes
        return SessionInfo(
            processedWidth: frame.width, processedHeight: frame.height,
            workWidth: Int(swaps ? s.native.height : s.native.width), workHeight: Int(swaps ? s.native.width : s.native.height),
            cameraOrientation: s.camera.rawValue)
    }

    public func sessionModules() async throws -> [ModuleInfo] {
        _ = try openedSession()
        return CIModule.all.map { m in
            ModuleInfo(operation: m.operation, name: m.name, iopOrder: m.iopOrder,
                       enabled: m.defaultEnabled, defaultEnabled: m.defaultEnabled,
                       params: Dictionary(uniqueKeysWithValues: m.fields.map { ($0.name, $0.defaultValue) }))
        }
    }

    public func exportRender(path: String, maxSide: Int, stack: [StackEntry]) async throws -> RenderedFrame {
        return try await render(path: path, maxSide: maxSide, stack: stack)
    }

    // MARK: one-shot

    public func render(path: String, maxSide: Int, stack: [StackEntry]) async throws -> RenderedFrame {
        guard context != nil else { throw EngineError("engine not started") }
        let s = try Self.makeSession(path: path, maxSide: maxSide)
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        let image = try edited(try decode(s, scale: s.fit, stack: stack), stack, camera: s.camera)
        return try frame(image, crop: nil, since: started)
    }

    // MARK: modules (none in M0)

    public func moduleNames() async throws -> [String] {
        CIModule.all.map(\.operation)
    }

    public func schema(for operation: String) async throws -> ModuleSchema {
        guard let m = CIModule.named(operation) else {
            throw EngineError("the clean engine has no module \(operation) yet")
        }
        return ModuleSchema(operation: m.operation, fields: m.fields)
    }

    public func defaultValue(operation: String, field: String) async throws -> Double? {
        CIModule.named(operation)?.defaultValue(field)
    }

    // MARK: helpers

    private func openedSession() throws -> Session {
        guard context != nil else { throw EngineError("engine not started") }
        guard let session else { throw EngineError("no image is open") }
        return session
    }

    /// `camera` is the orientation of the file being rendered: a one-shot render (thumbnails, export) has
    /// its own, never the open session's.
    private func edited(_ image: CIImage, _ stack: [StackEntry], camera: Orientation) throws -> CIImage {
        try Self.process(image, stack, camera: camera)
    }

    /// The whole edit on a sensor-orientation image: the per-pixel stack, then geometry. Static so
    /// `CIEngineProbe` runs this exact code.
    static func process(_ image: CIImage, _ stack: [StackEntry], camera: Orientation) throws -> CIImage {
        CIGeometry.apply(try CIGeometry.spec(stack, camera: camera), to: try applyStack(image, stack))
    }

    /// Applies the enabled stack entries in pipeline order. An operation the clean engine
    /// does not have is an error, never a silent skip. Static so `CIEngineProbe` runs this exact code.
    static func applyStack(_ image: CIImage, _ stack: [StackEntry]) throws -> CIImage {
        let ordered = try stack.filter { $0.enabled && !CIGeometry.operations.contains($0.operation) }.map { entry -> (CIModule, StackEntry) in
            guard let m = CIModule.named(entry.operation) else {
                throw EngineError("the clean engine has no module \(entry.operation) yet")
            }
            return (m, entry)
        }
        .sorted { $0.0.iopOrder < $1.0.iopOrder }

        var out = image
        for (m, entry) in ordered {
            let maskMode = entry.blend["mask_mode"]?.double ?? 0
            let before = out
            out = try m.apply(out, m.values(from: entry.params))
            if maskMode == 2 {
                // a local mask (DarkroomCore.Mask): cut from the module's input, then the output is mixed over it
                let blend = entry.blend.compactMapValues { $0.double }
                guard let spec = Mask.spec(from: blend) else {
                    throw EngineError("the clean engine has no mask kind \(blend["mask_kind"] ?? 0)")
                }
                let matte = try CIBridge.localMask(before, spec: spec)
                out = try CIBridge.blendMasked(before: before, after: out, mask: matte, opacity: spec.opacity)
                continue
            }
            guard maskMode == 0 || maskMode == 1 else {
                throw EngineError("the clean engine has no masks of mode \(maskMode) (drawn and parametric masks are not built)")
            }
            // opacity is a percentage: mix the module's output back over its input
            let opacity = min(max(entry.blend["opacity"]?.double ?? 100, 0), 100) / 100
            if opacity < 1 {
                let faded = out.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
                ])
                out = faded.composited(over: before)
            }
        }
        return out
    }

    private static func makeSession(path: String, maxSide: Int) throws -> Session {
        let url = URL(fileURLWithPath: path)
        guard let raw = CIRAWFilter(imageURL: url) else {
            throw EngineError("cannot decode \(url.lastPathComponent)")
        }
        let native = raw.nativeSize
        let long = max(native.width, native.height)
        let fit = long > 0 ? min(1, Double(maxSide) / Double(long)) : 1
        return Session(url: url, raw: raw, native: native, fit: fit, maxSide: maxSide,
                       boost: raw.boostAmount, localToneMap: raw.localToneMapAmount,
                       camera: CIGeometry.orientation(exif: raw.orientation))
    }

    /// Decode at `scale` of the native size. Decoding small is what makes open fast:
    /// the RAW decoder does the downscale, not a later resample. With a scene-referred module on,
    /// the decoder's boost curve and local tone map are off, so that module sees scene-linear light.
    private func decode(_ s: Session, scale: Double, stack: [StackEntry]) throws -> CIImage {
        s.raw.scaleFactor = Float(scale)
        let sceneLinear = Self.wantsSceneLinear(stack)
        // assign only on a change: setting a filter property can drop the decoder's cached output
        let boost = sceneLinear ? 0 : s.boost, localToneMap = sceneLinear ? 0 : s.localToneMap
        if s.raw.boostAmount != boost { s.raw.boostAmount = boost }
        if s.raw.localToneMapAmount != localToneMap { s.raw.localToneMapAmount = localToneMap }
        // always the sensor's orientation: geometry turns it upright (see Session.camera)
        if s.raw.orientation != .up { s.raw.orientation = .up }
        guard let image = s.raw.outputImage else {
            throw EngineError("decode failed")
        }
        return image
    }

    static func wantsSceneLinear(_ stack: [StackEntry]) -> Bool {
        stack.contains { $0.enabled && CIModule.named($0.operation)?.sceneReferred == true }
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
