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
        /// The camera's orientation. The decoder runs in sensor orientation (`native` is the sensor's size)
        /// and geometry applies this as the default flip, as darktable orders it.
        let camera: Orientation

        /// The decoded size at scale 1 (the working frame), in sensor orientation.
        var sensorFrame: CGSize { CGSize(width: (native.width * fit).rounded(), height: (native.height * fit).rounded()) }
    }

    private var context: CIContext?
    /// Keeps the picture after each neighbourhood module (see SegmentCache), for the open session's renders only.
    private var segmentCache: SegmentCache?
    private var session: Session?
    private var clippingOverlay = false
    private var maskRasters: [String: MaskRaster] = [:]
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
        context = made
        if let space = made.workingColorSpace { segmentCache = SegmentCache(context: made, device: device, space: space) }
    }

    /// The one definition of the engine's Core Image context: linear sRGB primaries (unclamped, so scene light above 1 survives) in half
    /// float, named explicitly so an OS default cannot move it. Every module's kernel works in this space (the OkLab matrices and
    /// luminance weights are sRGB's), the segment cache's textures hold it, and `SegmentProbe` builds its context here so
    /// darkroom-engine-check measures what the app runs.
    static func makeContext(device: MTLDevice) -> CIContext {
        var options: [CIContextOption: Any] = [.cacheIntermediates: true, .workingFormat: CIFormat.RGBAh]
        if let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) { options[.workingColorSpace] = space }
        return CIContext(mtlDevice: device, options: options)
    }

    public func shutdown() async {
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
        let s = try openedSession()
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        var image = try edited(try decode(s, scale: s.fit * scale, stack: stack), stack, camera: s.camera, scale: s.fit * scale, session: s)
        if clippingOverlay { image = try CIBridge.clippingOverlay(image) }
        // the viewport's frame is 8 bits: dither the last step so a smooth shadow does not break into bands (exports keep their own bits)
        return try frame(try CIBridge.dither8(image), crop: nil, since: started)
    }

    public func sessionRenderRegion(stack: [StackEntry], scale: Double, x: Int, y: Int,
                                    width: Int, height: Int) async throws -> RenderedFrame {
        let s = try openedSession()
        cancelFlag.withLock { $0 = false }
        let started = ContinuousClock.now
        var image = try edited(try decode(s, scale: s.fit * scale, stack: stack), stack, camera: s.camera, scale: s.fit * scale, session: s)
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
                           (f.name, m.operation == "display" && f.name == "exposure" ? .number(CIModule.defaultExposureBias) : f.defaultValue)
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

    private func edited(_ image: CIImage, _ stack: [StackEntry], camera: Orientation, scale: Double = 1, session: Session? = nil) throws -> CIImage {
        // only the open session's renders keep segments: an export or a thumbnail has a session of its own that nothing returns to
        var segments: Segments?
        if let session, let segmentCache {
            // what the decoder hands over depends on the scene-referred switch and the working size, so both are in the key
            segments = Segments(cache: segmentCache, base: "\(session.id)|\(Self.wantsSceneLinear(stack))|\(maskRasterRevision)")
        }
        return try Self.process(image, stack, camera: camera, scale: scale, rasters: maskRasters, segments: segments)
    }

    /// The whole edit on a sensor-orientation image: the per-pixel stack, then geometry. Static so
    /// `CIEngineProbe` runs this exact code.
    /// `hdrPeak` (linear, SDR white = 1) renders the HDR version of the image: the display transform lets highlights
    /// past 1 up to that peak; nil is the ordinary SDR render.
    /// `scale` is the render's size against native pixels (1 = full resolution): modules that work over a radius in
    /// pixels (sharpen, local contrast, haze removal, mask refinement) take their radius as full-resolution pixels and
    /// shrink it by `scale`, so a preview looks like the export (roadmap T9).
    static func process(_ image: CIImage, _ stack: [StackEntry], camera: Orientation, hdrPeak: Double? = nil,
                        scale: Double = 1, rasters: [String: MaskRaster] = [:], segments: Segments? = nil) throws -> CIImage {
        CIGeometry.apply(try CIGeometry.spec(stack, camera: camera),
                         to: try applyStack(image, stack, hdrPeak: hdrPeak, scale: scale, camera: camera, rasters: rasters, segments: segments))
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
                           camera: Orientation = .none, rasters: [String: MaskRaster] = [:], segments: Segments? = nil) throws -> CIImage {
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
        var start = 0
        if let segments, !ordered.contains(where: { ($0.1.blend["mask_show"]?.double ?? 0) != 0 }) {
            var prefix = "\(segments.base)|\(hdrPeak.map { "\($0)" } ?? "sdr")|\(scale)|\(camera.rawValue)"
            for (i, (m, entry)) in ordered.enumerated() {
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
        // Pure gains (white balance, exposure) multiply on their own, so a run of them is one multiply: it is carried along and
        // either joins the display transform's kernel or is applied as one pass just before the next module that is not a gain.
        var pendingGain: SIMD3<Double>?
        for (index, (m, entry)) in ordered.enumerated() {
            if index < start { continue }
            let maskMode = entry.blend["mask_mode"]?.double ?? 0
            var values = m.values(from: entry.params)
            if maskMode == 0, (entry.blend["opacity"]?.double ?? 100) >= 100, let g = CIModule.foldableGain(m.operation, values) {
                if g != SIMD3(1, 1, 1) { pendingGain = (pendingGain ?? SIMD3(1, 1, 1)) * g }
                continue
            }
            if let gain = pendingGain {
                if m.operation == "display" {
                    values["_gain_r"] = gain.x; values["_gain_g"] = gain.y; values["_gain_b"] = gain.z
                } else {
                    out = try CIBridge.gain(out, scale: gain)
                }
                pendingGain = nil
            }
            let before = out
            if let hdrPeak, m.operation == "display" { values["peak"] = hdrPeak }
            values["_scale"] = scale.isFinite ? min(max(scale, 1e-3), 1) : 1
            values["_camera"] = Double(camera.rawValue)   // modules that draw their own matte need the upright picture
            out = try m.apply(out, values)
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
        if let gain = pendingGain { out = try CIBridge.gain(out, scale: gain) }
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
        // always the sensor's orientation: geometry turns it upright (see Session.camera)
        if s.raw.orientation != .up { s.raw.orientation = .up }
        guard let image = s.raw.outputImage else {
            throw EngineError("decode failed")
        }
        return image
    }

    /// Where a module runs: its own `iopOrder`, except that display-referred modules (the tone curve) follow the
    /// scene-referred display transform when one is on.
    static func effectiveOrder(_ m: CIModule, sceneReferred: Bool) -> Double {
        sceneReferred && CIModule.displayReferredOperations.contains(m.operation) ? 90 + Double(m.iopOrder) / 1000 : Double(m.iopOrder)
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
