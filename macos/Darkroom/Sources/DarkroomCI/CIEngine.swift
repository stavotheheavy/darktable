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
        let id = UUID()
        let url: URL
        let raw: CIRAWFilter
        let native: CGSize
        /// Native pixels to working-frame pixels for the maxSide this session was opened at.
        let fit: Double
        let maxSide: Int
        /// The decoder's own tone settings, restored when no scene-referred module is on.
        let boost: Float
        let localToneMap: Float
        let boostShadow: Float
        let shadowBias: Float
        let sharpness: Float
        let gamutMapping: Bool
        /// The camera's orientation. The decoder runs in sensor orientation (`native` is the sensor's size)
        /// and geometry applies this as the default flip, as darktable orders it.
        let camera: Orientation

        /// The decoded size at scale 1 (the working frame), in sensor orientation.
        /// Core Image's RAW decoder rounds a scaled size UP (933.33 gives 934, measured with `dtb-selftest --stack` at --max 1400 and 2000), so the
        /// size told to the UI does the same; the small tolerance keeps a size that is whole up to float error from tipping over.
        var sensorFrame: CGSize { CGSize(width: (native.width * fit - 1e-6).rounded(.up), height: (native.height * fit - 1e-6).rounded(.up)) }
    }

    private var context: CIContext?
    private var metalDevice: MTLDevice?
    /// The textures `sessionRenderPresentable` renders into, three per size in turn: the app presents one while the next renders.
    private var presentPool: [String: [MTLTexture]] = [:]
    private var presentCount = 0
    /// The display-linear peak of presented frames (1 = SDR); see PhotoEngine.setPreviewPeak.
    private var previewPeak = 1.0
    /// Keeps the picture after each neighbourhood module (see SegmentCache), for the open session's renders only.
    private var segmentCache: SegmentCache?
    private var session: Session?
    private var clippingOverlay = false
    private var maskRasters: [String: MaskRaster] = [:]
    /// Whether session renders start from the engine's owned decode texture (on); off asks the decoder at each size, as before. For the
    /// self-test's comparison of the two (T9).
    private var ownedDecodeOn = true
    /// Bumped whenever the mask pictures are replaced: a raster mask's pixels are not in the stack entry.
    private var maskRasterRevision = 0

    /// Set from any thread by `cancelRender()`; checked between decode and render.
    private let cancelFlag = Mutex(false)

    public init() {}

    public func start(prefix: URL, configDir: URL, cacheDir: URL) async throws {
        // prefix, configDir and cacheDir belong to darktable; the clean engine needs none.
        guard context == nil else { return }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EngineError("no Metal device for Core Image")
        }
        let made = Self.makeContext(device: device)
        metalDevice = device
        context = made
        if let space = made.workingColorSpace { segmentCache = SegmentCache(context: made, device: device, space: space) }
    }

    /// The engine's working space: linear Rec.2020 primaries, unclamped (see ColorSpaces.workingToXYZ).
    static let workingSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

    /// The one definition of the engine's Core Image context: the working space above in half float, named explicitly so an OS default
    /// cannot move it. Every module's kernel works in this space (the OkLab matrices and luminance weights are derived from it), the
    /// segment cache's textures hold it, and `SegmentProbe` builds its context here so darkroom-engine-check measures what the app runs.
    static func makeContext(device: MTLDevice) -> CIContext {
        CIContext(mtlDevice: device, options: [.cacheIntermediates: true, .workingFormat: CIFormat.RGBAh, .workingColorSpace: workingSpace])
    }

    public func shutdown() async {
        presentPool.removeAll()
        session = nil
        segmentCache?.clear()
        segmentCache = nil
        context = nil
    }

    // MARK: session

    public func openSession(path: String, maxSide: Int) async throws {
        guard context != nil else { throw EngineError("engine not started") }
        session = nil
        segmentCache?.clear()
        session = try Self.makeSession(path: path, maxSide: maxSide)
    }

    public func closeSession() async {
        session = nil
        segmentCache?.clear()
    }

    public nonisolated func cancelRender() {
        cancelFlag.withLock { $0 = true }
    }

    public func sessionRender(stack: [StackEntry], scale: Double) async throws -> RenderedFrame {
        let stack = CIModule.withDefaults(stack)
        let s = try openedSession()
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        var image = try edited(try ownedDecode(s, scale: scale, stack: stack), stack, camera: s.camera, scale: s.fit * scale, session: s)
        if clippingOverlay { image = try CIBridge.clippingOverlay(image) }
        // the viewport's frame is 8 bits: dither the last step so a smooth shadow does not break into bands (exports keep their own bits)
        return try frame(try CIBridge.dither8(image), crop: nil, since: started)
    }

    public func sessionRenderRegion(stack: [StackEntry], scale: Double, x: Int, y: Int,
                                    width: Int, height: Int) async throws -> RenderedFrame {
        let stack = CIModule.withDefaults(stack)
        let s = try openedSession()
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        var image = try edited(try ownedDecode(s, scale: scale, stack: stack), stack, camera: s.camera, scale: s.fit * scale, session: s)
        if clippingOverlay { image = try CIBridge.clippingOverlay(image) }
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

    public func setPreviewPeak(_ peak: Double) async {
        previewPeak = peak.isFinite ? min(max(peak, 1), 8) : 1
    }

    public func sessionRenderPresentable(stack: [StackEntry], scale: Double) async throws -> PresentedFrame? {
        let stack = CIModule.withDefaults(stack)
        let s = try openedSession()
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        var image = try edited(try ownedDecode(s, scale: scale, stack: stack), stack, camera: s.camera, scale: s.fit * scale, session: s, target: .displayP3, hdrPeak: previewPeak > 1 ? previewPeak : nil)
        if clippingOverlay { image = try CIBridge.clippingOverlay(image) }
        return try presented(image, crop: nil, since: started)
    }

    public func sessionRenderRegionPresentable(stack: [StackEntry], scale: Double, x: Int, y: Int,
                                               width: Int, height: Int) async throws -> PresentedFrame? {
        let stack = CIModule.withDefaults(stack)
        let s = try openedSession()
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        var image = try edited(try ownedDecode(s, scale: scale, stack: stack), stack, camera: s.camera, scale: s.fit * scale, session: s, target: .displayP3, hdrPeak: previewPeak > 1 ? previewPeak : nil)
        if clippingOverlay { image = try CIBridge.clippingOverlay(image) }
        let ext = image.extent.integral
        let wanted = CGRect(x: ext.minX + CGFloat(x), y: ext.maxY - CGFloat(y) - CGFloat(height), width: CGFloat(width), height: CGFloat(height))
        let crop = wanted.intersection(ext)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { throw EngineError("region lies outside the image") }
        return try presented(image, crop: crop, since: started)
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
        guard let cg = EmbeddedPreview.read(path: s.url.path, maxSide: s.maxSide) else { return nil }
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
            // every per-pixel module can blend through a local mask; geometry and the display transform cannot
            let blends = !m.geometry && m.operation != "display"
            return ModuleInfo(operation: m.operation, name: m.name, iopOrder: m.iopOrder,
                       enabled: m.defaultEnabled, defaultEnabled: m.defaultEnabled,
                       supportsBlending: blends, noMasks: !blends,
                       params: Dictionary(uniqueKeysWithValues: m.fields.map { f in
                           (f.name, CIModule.startParams[m.operation]?[f.name] ?? f.defaultValue)
                       }),
                       blend: blends ? BlendInfo() : nil)
        }
    }

    public func setClippingOverlay(_ on: Bool) async { clippingOverlay = on }

    public func setMaskRasters(_ rasters: [MaskPicture]) async {
        maskRasterRevision += 1
        maskRasters = Dictionary(rasters.filter { $0.width > 0 && $0.height > 0 && $0.pixels.count == $0.width * $0.height }
            .map { ($0.id, MaskRaster(id: $0.id, width: $0.width, height: $0.height, pixels: $0.pixels)) }) { $1 }
    }

    public func algorithmVersions() async -> [String: Int] {
        Dictionary(uniqueKeysWithValues: CIModule.all.map { ($0.operation, $0.algorithmVersion) })
    }

    public func exportRender(path: String, maxSide: Int, stack: [StackEntry]) async throws -> RenderedFrame {
        return try await render(path: path, maxSide: maxSide, stack: stack)
    }

    /// The export as a JPEG with an HDR gain map, `headroom` times SDR white at the brightest. With the display
    /// transform on, the HDR version is that transform with a higher peak; without it, Apple's own RAW HDR rendition.
    public func exportHDRJPEG(path: String, maxSide: Int, stack: [StackEntry], headroom: Double) async throws -> Data? {
        let stack = CIModule.withDefaults(stack)
        guard let context else { throw EngineError("engine not started") }
        let s = try Self.makeSession(path: path, maxSide: maxSide)
        cancelFlag.withLock { $0 = false }
        let peak = min(max(headroom, 1), 8)
        if Self.wantsSceneLinear(stack) {
            let decoded = try decode(s, scale: s.fit, stack: stack)
            let sdr = try Self.process(decoded, stack, camera: s.camera, scale: s.fit, rasters: maskRasters)
            let hdr = try Self.process(decoded, stack, camera: s.camera, hdrPeak: peak, scale: s.fit, rasters: maskRasters)
            return try Self.hdrJPEG(context: context, sdr: sdr, hdr: hdr, headroom: peak)
        }
        let sdr = try edited(try decode(s, scale: s.fit, stack: stack, edr: 0), stack, camera: s.camera, scale: s.fit)
        let hdr = try edited(try decode(s, scale: s.fit, stack: stack, edr: 1), stack, camera: s.camera, scale: s.fit)
        return try Self.hdrJPEG(context: context, sdr: sdr, hdr: hdr, headroom: peak)
    }

    // MARK: one-shot

    public func render(path: String, maxSide: Int, stack: [StackEntry]) async throws -> RenderedFrame {
        let stack = CIModule.withDefaults(stack)
        guard context != nil else { throw EngineError("engine not started") }
        let s = try Self.makeSession(path: path, maxSide: maxSide)
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        let image = try edited(try decode(s, scale: s.fit, stack: stack), stack, camera: s.camera, scale: s.fit)
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
    /// A JPEG of the SDR render that carries an HDR gain map (Core Image computes the single-channel map from the ratio of
    /// the HDR version to the SDR one). `sdr` and `hdr` are the same edit rendered with and without the display
    /// transform's peak; a viewer that knows gain maps shows `headroom` times SDR white at the brightest, any other
    /// shows the SDR picture. Static so `CIEngineProbe` runs this exact code.
    static func hdrJPEG(context: CIContext, sdr: CIImage, hdr: CIImage, headroom: Double, quality: Double = 0.92) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw EngineError("no sRGB colour space") }
        let rect = sdr.extent.integral
        let base = sdr.cropped(to: rect)
        let lifted = hdr.cropped(to: rect).settingContentHeadroom(Float(max(headroom, 1)))
        let options: [CIImageRepresentationOption: Any] = [
            .hdrImage: lifted,
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        guard let data = context.jpegRepresentation(of: base, colorSpace: space, options: options) else {
            throw EngineError("could not write the HDR JPEG")
        }
        return data
    }

    private func edited(_ image: CIImage, _ stack: [StackEntry], camera: Orientation, scale: Double = 1, session: Session? = nil,
                        target: OutputGamut = .sRGB, hdrPeak: Double? = nil) throws -> CIImage {
        // only the open session's renders keep segments: an export or a thumbnail has a session of its own that nothing returns to
        var segments: Segments?
        if let session, let segmentCache {
            // what the decoder hands over depends on the scene-referred switch and the working size, so both are in the key
            segments = Segments(cache: segmentCache, base: "\(session.id)|\(Self.wantsSceneLinear(stack))|\(maskRasterRevision)")
        }
        return try Self.process(image, stack, camera: camera, hdrPeak: hdrPeak, scale: scale, rasters: maskRasters, segments: segments,
                                fuse: Self.fusionEnabled, target: target)
    }

    /// The owned decode texture is on unless DARKROOM_NO_OWNED_DECODE is set (to compare against the decoder's own reduced-size decode).
    static let ownedDecodeEnabled = ProcessInfo.processInfo.environment["DARKROOM_NO_OWNED_DECODE"] == nil

    /// Fused per-pixel passes are on unless DARKROOM_NO_FUSE is set (to time or debug the one-pass-per-module path).
    static let fusionEnabled = ProcessInfo.processInfo.environment["DARKROOM_NO_FUSE"] == nil

    /// The whole edit on a sensor-orientation image: the per-pixel stack, then geometry. Static so
    /// `CIEngineProbe` runs this exact code.
    /// `hdrPeak` (linear, SDR white = 1) renders the HDR version of the image: the display transform lets highlights
    /// past 1 up to that peak; nil is the ordinary SDR render.
    /// `scale` is the render's size against native pixels (1 = full resolution): modules that work over a radius in
    /// pixels (sharpen, local contrast, haze removal, mask refinement) take their radius as full-resolution pixels and
    /// shrink it by `scale`, so a preview looks like the export (roadmap T9).
    static func process(_ image: CIImage, _ stack: [StackEntry], camera: Orientation, hdrPeak: Double? = nil,
                        scale: Double = 1, rasters: [String: MaskRaster] = [:], segments: Segments? = nil, fuse: Bool = true,
                        target: OutputGamut = .sRGB) throws -> CIImage {
        CIGeometry.apply(try CIGeometry.spec(stack, camera: camera),
                         to: try applyStack(image, stack, hdrPeak: hdrPeak, scale: scale, camera: camera, rasters: rasters, segments: segments,
                                            fuse: fuse, target: target))
    }

    /// A segment cache and the text that identifies the decoded picture the stack starts from (photo, decode scale and settings).
    struct Segments {
        let cache: SegmentCache
        let base: String
    }

    /// The text of one stack entry that decides its pixels.
    static func fingerprint(_ e: StackEntry) -> String {
        let params = e.params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let blend = e.blend.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "\(e.operation)|\(e.enabled)|\(params)|\(blend)"
    }

    /// Applies the enabled stack entries in pipeline order. An operation the clean engine
    /// does not have is an error, never a silent skip. Static so `CIEngineProbe` runs this exact code.
    static func applyStack(_ image: CIImage, _ stack: [StackEntry], hdrPeak: Double? = nil, scale: Double = 1,
                           camera: Orientation = .none, rasters: [String: MaskRaster] = [:], segments: Segments? = nil,
                           fuse: Bool = true, target: OutputGamut = .sRGB) throws -> CIImage {
        let sceneReferred = wantsSceneLinear(stack)
        let ordered = try stack.filter { $0.enabled && !CIGeometry.operations.contains($0.operation) }.map { entry -> (CIModule, StackEntry) in
            guard let m = CIModule.named(entry.operation) else {
                throw EngineError("the clean engine has no module \(entry.operation) yet")
            }
            return (m, entry)
        }
        .sorted { Self.effectiveOrder($0.0, sceneReferred: sceneReferred) < Self.effectiveOrder($1.0, sceneReferred: sceneReferred) }

        var out = image
        // a module's mask drawn over the picture while it is edited (render-only: the model never puts this in an export)
        var showMatte: CIImage?

        // Segment cache: after each neighbourhood module the result is kept in a texture under a key made of the picture and every
        // entry so far; a render starts from the deepest boundary whose key is still there. A render that draws a mask over the
        // picture skips the cache (the matte is made inside the loop).
        var boundaryKeys: [Int: String] = [:]
        // the text identifying the picture a module receives, for the zone exposure's base (which does not depend on its own settings)
        var inputKeys: [Int: String] = [:]
        var start = 0
        if let segments, !ordered.contains(where: { ($0.1.blend["mask_show"]?.double ?? 0) != 0 }) {
            var prefix = "\(segments.base)|\(hdrPeak.map { "\($0)" } ?? "sdr")|\(scale)|\(camera.rawValue)|\(target)"
            for (i, (m, entry)) in ordered.enumerated() {
                inputKeys[i] = prefix
                prefix += "\n" + fingerprint(entry)
                if CIModule.neighbourhoodOperations.contains(m.operation) { boundaryKeys[i] = prefix }
            }
            for i in boundaryKeys.keys.sorted(by: >) {
                if let cached = segments.cache.lookup(boundaryKeys[i]!) { out = cached; start = i + 1; break }
            }
        }
        func keep(_ index: Int) {
            guard let segments, let key = boundaryKeys[index] else { return }
            out = segments.cache.store(out, key: key)
        }
        // A run of per-pixel modules (white balance, exposure, colour balance, mixer, the curves, the display transform...) is one pass over
        // the frame: their ops pile up here and are flushed as one fused kernel just before the next module that is not one of them (or at
        // the end). `fuse: false` (the checks) runs them one by one instead, to prove the two agree.
        var pending: [FusedOp] = []
        func flush() throws {
            if !pending.isEmpty { out = try CIBridge.fused(out, ops: pending); pending = [] }
        }
        for (index, (m, entry)) in ordered.enumerated() {
            if index < start { continue }
            let maskMode = entry.blend["mask_mode"]?.double ?? 0
            var values = m.values(from: entry.params)
            if let hdrPeak, m.operation == "display" { values["peak"] = hdrPeak }
            if m.operation == "display" { values["_target"] = Double(target.rawValue) }   // the gamut the display transform maps into
            if fuse, maskMode == 0, (entry.blend["opacity"]?.double ?? 100) >= 100, CIModule.fusableOperations.contains(m.operation) {
                if let op = CIModule.fusedOp(m.operation, values) { pending.append(op) }
                continue
            }
            try flush()
            let before = out
            values["_scale"] = scale.isFinite ? min(max(scale, 1e-3), 1) : 1
            values["_camera"] = Double(camera.rawValue)   // modules that draw their own matte need the upright picture
            if m.operation == "zones", let segments, let inputKey = inputKeys[index] {
                // the base (a guided filter, the expensive half) is kept under the picture it was made from and its radius, so moving a
                // zone slider re-runs only the one-pass gain
                let settings = ZoneExposure.Settings(values: values)
                if !settings.isIdentity {
                    let e = out.extent
                    let radius = ZoneExposure.radius(scale: settings.scale, longSide: Int(max(e.width, e.height)))
                    let baseKey = inputKey + "\nzone-base|\(radius)|\(e.width)x\(e.height)"
                    let base: CIImage
                    if let kept = segments.cache.lookup(baseKey) { base = kept } else {
                        base = segments.cache.store(try CIBridge.zoneBase(out, radius: radius), key: baseKey)
                    }
                    out = try CIBridge.zoneGain(out, base: base, evs: settings.zoneEVs)
                }
            } else {
                out = try m.apply(out, values)
            }
            // a Core Image filter may grow its output (bloom spreads past the edge) or leave it infinite (a clamped blur):
            // a per-pixel module never changes the frame, geometry does that
            if out.extent != before.extent { out = out.cropped(to: before.extent) }
            if maskMode == 2 {
                // a local mask (DarkroomCore.Mask): cut from the module's input, then the output is mixed over it
                let blend = entry.blend.compactMapValues { $0.double }
                guard var spec = Mask.spec(from: blend) else {
                    throw EngineError("the clean engine has no mask kind \(blend["mask_kind"] ?? 0)")
                }
                spec.orientation = camera   // masks are drawn on the upright picture; this frame is the sensor's
                if spec.kind == 5 { spec.raster = entry.blend["mask_raster"]?.option.flatMap { rasters[$0] } }
                if spec.refineRadius > 0 { spec.refineRadius = max(1, Int((Double(spec.refineRadius) * min(max(scale, 1e-3), 1)).rounded())) }
                let matte = try CIBridge.localMask(before, spec: spec)
                out = try CIBridge.blendMasked(before: before, after: out, mask: matte, opacity: spec.opacity)
                if (blend["mask_show"] ?? 0) != 0 { showMatte = matte }
                keep(index)
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
            keep(index)
        }
        try flush()
        if let showMatte {
            // red over the masked part: alpha 0.5 where the matte is 1 (a hair stronger so thin masks read)
            let tint = showMatte.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 1, y: 0.12, z: 0.12, w: 0),
            ])
            out = tint.composited(over: out).cropped(to: out.extent)
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
                       boostShadow: raw.boostShadowAmount, shadowBias: raw.shadowBias, sharpness: raw.sharpnessAmount,
                       gamutMapping: raw.isGamutMappingEnabled,
                       camera: CIGeometry.orientation(exif: raw.orientation))
    }

    /// Decode at `scale` of the native size. Decoding small is what makes open fast:
    /// the RAW decoder does the downscale, not a later resample. With a scene-referred module on, the decoder
    /// hands over scene-linear light with no look of its own: its boost curve, local tone map and shadow lift are
    /// off, its shadow bias (a black-point clip) is zero, sharpening is left to our module, and extended range is
    /// on so highlights past white are kept instead of clipped at 1.0. `edr` overrides the extended-range amount.
    private func decode(_ s: Session, scale: Double, stack: [StackEntry], edr: Float? = nil) throws -> CIImage {
        s.raw.scaleFactor = Float(scale)
        let sceneLinear = Self.wantsSceneLinear(stack)
        // assign only on a change: setting a filter property can drop the decoder's cached output
        func set(_ current: Float, _ wanted: Float, _ write: (Float) -> Void) { if current != wanted { write(wanted) } }
        set(s.raw.boostAmount, sceneLinear ? 0 : s.boost) { s.raw.boostAmount = $0 }
        set(s.raw.localToneMapAmount, sceneLinear ? 0 : s.localToneMap) { s.raw.localToneMapAmount = $0 }
        set(s.raw.boostShadowAmount, sceneLinear ? 0 : s.boostShadow) { s.raw.boostShadowAmount = $0 }
        set(s.raw.shadowBias, sceneLinear ? 0 : s.shadowBias) { s.raw.shadowBias = $0 }
        set(s.raw.sharpnessAmount, sceneLinear ? 0 : s.sharpness) { s.raw.sharpnessAmount = $0 }
        set(s.raw.extendedDynamicRangeAmount, edr ?? (sceneLinear ? 1 : 0)) { s.raw.extendedDynamicRangeAmount = $0 }
        // the decoder compresses camera colour into its own gamut; the working space is wide enough to keep it, and the one gamut step is ours, at the end
        if s.raw.isGamutMappingEnabled != (sceneLinear ? false : s.gamutMapping) { s.raw.isGamutMappingEnabled = sceneLinear ? false : s.gamutMapping }
        // always the sensor's orientation: geometry turns it upright (see Session.camera)
        if s.raw.orientation != .up { s.raw.orientation = .up }
        guard let image = s.raw.outputImage else {
            throw EngineError("decode failed")
        }
        return image
    }

    /// The session's decoded picture as a texture the engine owns. The RAW is decoded once at the working size and kept (through the same
    /// cache the segments use); every render starts from that texture, so how often the decoder runs no longer depends on Core Image's own
    /// caching of `CIRAWFilter.outputImage`. A draft (`scale` under 1) is that same picture averaged down, never a second decode; a larger
    /// scale (zoomed regions) asks the decoder directly, as before.
    private func ownedDecode(_ s: Session, scale: Double, stack: [StackEntry]) throws -> CIImage {
        guard let cache = segmentCache, ownedDecodeOn, Self.ownedDecodeEnabled, scale <= 1.001, scale > 0, scale.isFinite else {
            return try decode(s, scale: s.fit * scale, stack: stack)
        }
        let key = "\(s.id)|decode|\(s.fit)|\(Self.wantsSceneLinear(stack))"
        let full: CIImage
        if let kept = cache.lookup(key) { full = kept } else { full = cache.store(try decode(s, scale: s.fit, stack: stack), key: key) }
        guard scale < 0.999 else { return full }
        let e = full.extent
        let w = max(1, (e.width * scale).rounded()), h = max(1, (e.height * scale).rounded())
        return full.samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: w / e.width, y: h / e.height))
            .cropped(to: CGRect(x: e.minX * w / e.width, y: e.minY * h / e.height, width: w, height: h))
    }

    public func setOwnedDecode(_ on: Bool) { ownedDecodeOn = on; segmentCache?.clear() }

    /// What the segment cache holds: for the self-test, which checks the decode runs once and drafts do not decode again.
    public func segmentCacheInfo() -> (entries: Int, hits: Int, misses: Int) {
        guard let c = segmentCache else { return (0, 0, 0) }
        return (c.count, c.hits, c.misses)
    }

    /// Where a module runs: its own `iopOrder`, except that display-referred modules (the tone curve) follow the
    /// scene-referred display transform when one is on.
    static func effectiveOrder(_ m: CIModule, sceneReferred: Bool) -> Double {
        sceneReferred && CIModule.displayReferredOperations.contains(m.operation) ? 90 + Double(m.iopOrder) / 1000 : Double(m.iopOrder)
    }

    static func wantsSceneLinear(_ stack: [StackEntry]) -> Bool {
        stack.contains { $0.enabled && CIModule.named($0.operation)?.sceneReferred == true }
    }

    /// Renders `image` into the next texture of the ring (16-bit float, linear, extended Display P3) and a small 8-bit copy of it for the
    /// scopes. No read-back of the full frame: the app presents the texture as it is.
    private func presented(_ image: CIImage, crop: CGRect?, since started: ContinuousClock.Instant) throws -> PresentedFrame {
        guard let context, let device = metalDevice else { throw EngineError("engine not started") }
        if cancelFlag.withLock({ $0 }) { throw RenderCanceled() }
        let rect = crop ?? image.extent.integral
        let w = Int(rect.width), h = Int(rect.height)
        guard w >= 1, h >= 1, w <= 16384, h <= 16384, let p3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw EngineError("could not render the frame") }
        let key = "\(w)x\(h)"
        if presentPool[key] == nil && presentPool.count >= 6 { presentPool.removeAll() }   // sizes come and go with the zoom
        var ring = presentPool[key] ?? []
        presentCount += 1
        let slot = presentCount % 3
        let texture: MTLTexture
        if slot < ring.count {
            texture = ring[slot]
        } else {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            desc.storageMode = .shared
            guard let made = device.makeTexture(descriptor: desc) else { throw EngineError("could not make a frame texture") }
            ring.append(made)
            presentPool[key] = ring
            texture = made
        }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = p3
        // Core Image's rows run bottom to top and a Metal texture's top to bottom: flipped, the texture's first row is the picture's top, which
        // is what a layer presents. (Left unflipped the picture showed upside down on screen while every round trip through
        // CIImage(mtlTexture:) looked right, because that init undoes the same flip: PT2 reads the texture's own rows.)
        destination.isFlipped = true
        do {
            try context.startTask(toRender: image, from: rect, to: destination, at: .zero).waitUntilCompleted()
        } catch {
            throw EngineError("could not render the frame: \(error)")
        }
        // the scopes' copy: the texture read as an image, averaged down to at most 640 px and read back
        let k = min(1, 640 / max(rect.width, rect.height))
        let tw = max(1, (rect.width * k).rounded()), th = max(1, (rect.height * k).rounded())
        // CIImage(mtlTexture:) reads the first row as the bottom, so a top-first texture comes back upside down: turn it over again
        guard let source = CIImage(mtlTexture: texture, options: [.colorSpace: p3])?.oriented(.downMirrored),
              let thumb = context.createCGImage(source.samplingLinear().transformed(by: CGAffineTransform(scaleX: tw / rect.width, y: th / rect.height)),
                                                from: CGRect(x: 0, y: 0, width: tw, height: th), format: .RGBA8, colorSpace: srgb) else {
            throw EngineError("could not make the frame's thumbnail")
        }
        let elapsed = started.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        return PresentedFrame(texture: texture, width: w, height: h, milliseconds: ms, thumbnail: thumb, peak: previewPeak)
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
