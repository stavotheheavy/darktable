import AppKit
import CoreGraphics
import DarkroomCI
import DarkroomCore
import DarktableKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Pro's three header menus.
public enum ProMenuKind: Hashable, Sendable { case modules, presets, history }

public enum LeftTab: String, CaseIterable, Sendable { case modules = "Modules", history = "History" }
public enum ScopeMode: String, CaseIterable, Sendable { case histogram = "Histogram", waveform = "Waveform", vectorscope = "Vector" }
public enum ZoomMode: String, CaseIterable, Sendable { case fit = "Fit", actual = "100%", double = "200%" }

public enum Stage: String, Sendable, CaseIterable { case raw = "Raw", scene = "Scene-referred", display = "Display" }

public struct PixelProbe: Equatable, Sendable {
    public var x: Int, y: Int
    public var r: Int, g: Int, b: Int
}

/// A module as the list shows it: the module plus what the edits make of it.
public struct ModuleRow: Identifiable, Equatable {
    public var id: String { module.id }
    public let module: ModuleInfo
    public let stage: Stage
    public let enabled: Bool
    public let edited: Bool
    public var title: String { module.title }
}

/// Everything the darkroom shows and does.
///
/// Edits are a snapshot map of what the user changed on top of darktable's imported
/// state; every change is a history step, so undo, redo and jumping to any step are
/// exact. Rendering is latest-wins through the persistent session.
public enum ProPanelOrder: String, CaseIterable, Sendable {
    case newest, pipeline
    public var title: String { self == .newest ? "Newest" : "Pipeline" }
}

@MainActor
@Observable
public final class DarkroomModel {
    /// The long side, in pixels, the viewport renders at: about four fifths of the largest screen's long edge in backing pixels (the
    /// canvas is never wider than the screen minus its panels), held to 1600...3200. A fixed 1600 was upscaled on every Retina canvas,
    /// which reads as soft; the segment cache (CIEngine) is what makes the larger frame as quick to edit. `DARKROOM_WORKING_SIZE`
    /// overrides it, which the self-test uses so its pixels do not depend on the machine's screen.
    public static var workingSize: Int {
        if let s = ProcessInfo.processInfo.environment["DARKROOM_WORKING_SIZE"], let v = Int(s), v >= 200 { return v }
        let longest = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 0
        return workingSize(forScreenLongSide: Double(longest))
    }

    /// `workingSize` for a screen whose long edge is `pixels` backing pixels.
    public static func workingSize(forScreenLongSide pixels: Double) -> Int {
        guard pixels.isFinite, pixels > 0 else { return 1600 }
        return min(max(Int((pixels * 0.8).rounded()), 1600), 3200)
    }

    // image
    public private(set) var frame: CGImage?
    /// The canvas presents the engine's frames as a Metal texture (16-bit, no read-back of the full frame) when this is on and the engine
    /// can; `frame` is then a small 8-bit copy for the scopes. The canvas switches it on; headless callers leave it off and get full CGImages.
    public var presentsTexture = false
    /// Show the HDR rendition on a screen with headroom above SDR white (a photo's highlights go brighter than the page, as an HDR export
    /// does). Off by default: it changes how every photo looks, so it is the photographer's call. Only has an effect while `hdrAvailable`.
    public var hdrPreview = UserDefaults.standard.bool(forKey: "darkroom.hdrPreview")
    /// The headroom the screen can show right now, as a multiple of SDR white. macOS raises the screen's current value (what the panel can show
    /// at the present brightness) once a layer asks for extended-range content, and its "potential" is the most it could ever reach; so the
    /// current value is used once it is above 1 and the potential before that (the first HDR frame). A test sets `headroomOverride` instead
    /// of having a display.
    nonisolated(unsafe) public static var headroomOverride: Double?
    public static var screenHeadroom: Double {
        if let o = headroomOverride { return o }
        if let s = ProcessInfo.processInfo.environment["DARKROOM_EDR_HEADROOM"], let v = Double(s), v >= 1 { return v }
        let screen = NSApp?.windows.first(where: { $0.isVisible && $0.frame.width > 400 })?.screen ?? NSScreen.main
        let current = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        let potential = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        return current > 1.05 ? current : max(current, potential)
    }
    /// Whether the HDR preview can do anything here: the canvas presents textures and a screen has headroom.
    public var hdrAvailable: Bool { presentsTexture && Self.screenHeadroom > 1.05 }
    /// The display-linear peak the canvas frames are rendered with: 1 is SDR.
    public var previewPeak: Double { hdrPreview && hdrAvailable ? min(Self.screenHeadroom, 4) : 1 }

    /// Replace the canvas with a synthetic HDR and wide-gamut card (TestCard), to check the display path by eye. A session setting, off at launch.
    public var testCard = false

    public func setTestCard(_ on: Bool) {
        testCard = on
        requestRender()
    }

    /// The engine's grey-world white balance gains for the open photo (see autoWhiteBalance).
    public func measureAutoWhiteBalance() async -> [Double]? { try? await engine.sessionAutoWhiteBalance() }

    public func setHDRPreview(_ on: Bool) {
        hdrPreview = on
        UserDefaults.standard.set(on, forKey: "darkroom.hdrPreview")
        requestRender()
    }

    /// The frame as a texture, when the last render was presented that way.
    public private(set) var frameTexture: PresentedFrame?
    /// Counts presented frames, so a view can tell a new one from the same texture reused.
    public private(set) var frameSerial = 0
    /// The picture's real size when `frame` is only a thumbnail of it.
    public private(set) var frameFullSize: CGSize?
    /// The size of the picture on screen, whichever form the frame has.
    public var frameSize: CGSize? { frameFullSize ?? frame.map { CGSize(width: $0.width, height: $0.height) } }
    public private(set) var fileName = "No image"
    public private(set) var filePath: String?
    public private(set) var exifLine = ""
    public private(set) var status = "Open a raw to begin"
    public private(set) var lastMilliseconds: Double?
    public private(set) var info: SessionInfo?
    /// The output size at scale 1 for the stack last rendered, from the engine when it can tell (crop,
    /// straighten and flip change it); nil means `info`'s processed size holds.
    public private(set) var outputSize: (width: Int, height: Int)?
    /// The size zoom and pan work in: the output size when known, else the processed size.
    /// Pro's unfolded sections (by module id), for this session; membership itself lives in the edits.
    public var proOpen: Set<String> = []
    /// How Pro's panel stacks its sections: the one switched on last at the top (the owner's history view), or in the
    /// order the engine applies them (masks and geometry read better that way). Remembered across launches.
    public private(set) var proPanelOrder: ProPanelOrder =
        ProPanelOrder(rawValue: UserDefaults.standard.string(forKey: "darkroom.proPanelOrder") ?? "") ?? .newest
    public func setProPanelOrder(_ o: ProPanelOrder) {
        proPanelOrder = o
        UserDefaults.standard.set(o.rawValue, forKey: "darkroom.proPanelOrder")
    }
    /// The sensor frame at scale 1 and the camera's orientation, for Simple's geometry controls; nil when
    /// the engine cannot report them (see `simpleGeometryReady`).
    var geometryBase: (sensor: SIMD2<Double>, camera: Orientation)?
    public var imageSize: CGSize? {
        if let o = outputSize { return CGSize(width: o.width, height: o.height) }
        return info.map { CGSize(width: $0.processedWidth, height: $0.processedHeight) }
    }

    // modules
    public private(set) var modules: [ModuleInfo] = []
    public private(set) var schemas: [String: ModuleSchema] = [:]
    public var selectedID: String?
    public var moduleQuery = ""
    public var activeOnly = false
    public var showDeprecated = false
    public var blendOpen = false { didSet { if !blendOpen { maskShowID = nil; paintModuleID = nil } } }
    /// Which of Pro's header menus is open (the popover under its button), or nil.
    public var proMenuOpen: ProMenuKind? { didSet { if proMenuOpen != oldValue { proMenuQuery = "" } } }
    /// What the Modules dropdown's search field holds.
    public var proMenuQuery = ""
    /// Which drag on the tone curve is running (one history step per drag).
    var curveDragSerial = 0
    /// The painted and detected masks of the open photo (saved in its sidecar and masks folder).
    public private(set) var maskLayers: [MaskLayer] = []
    /// The module whose brush layer takes strokes from the photo, and the brush.
    public var paintModuleID: String?
    public var brushRadius = 0.04
    public var brushSoftness = 0.5
    public var brushFlow = 1.0
    public var brushErase = false
    /// What a running detection is doing ("Finding the subject…"), or nil.
    public private(set) var maskBusy: String?
    private var rasterCache: [String: MaskPicture] = [:]
    private var shippedRasterIDs: Set<String> = []
    /// Blown highlights red and crushed shadows blue on the picture (the J key). Display-only; exports never carry it.
    public var showClipping = false {
        didSet { if showClipping != oldValue { let on = showClipping; Task { await engine.setClippingOverlay(on); requestRender() } } }
    }
    /// The module whose mask is drawn over the photo (red), or nil. Render-only: exports never carry it.
    public var maskShowID: String? { didSet { if maskShowID != oldValue { requestRender() } } }

    // edits and history
    public private(set) var edits: EditMap = [:]
    public private(set) var history: [HistoryItem] = [HistoryItem(label: "original", detail: "", edits: [:])]
    public private(set) var historyIndex = 0
    public private(set) var snapshotEdits: EditMap?
    public private(set) var snapshotTime: Date?

    // view
    /// The header's Hide UI: every panel fades out so the photo is seen whole.
    public var uiHidden = false
    /// Set by the window root so the darkroom can return to the library.
    public var onBack: (() -> Void)?
    /// Simple or Pro, remembered between launches; the same file and edits either way.
    public var mode: EditMode = EditMode.load() {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: EditMode.key) }
    }
    public var leftTab: LeftTab = .modules
    public var scopeMode: ScopeMode = .histogram
    public var zoom: ZoomMode = .fit { didSet { if zoom != oldValue { requestRender() } } }
    public var showingOriginal = false { didSet { if showingOriginal != oldValue { requestRender() } } }
    public var showingSnapshot = false { didSet { if showingSnapshot != oldValue { requestRender() } } }
    public var viewport = CGSize(width: 1000, height: 700)
    /// What sits behind the photo; remembered between launches.
    public var backdrop: BackdropStyle = BackdropStyle.load() {
        didSet { if backdrop != oldValue { backdrop.save() } }
    }
    /// Where the zoomed view looks, as 0...1 of the output image.
    public private(set) var center = CGPoint(x: 0.5, y: 0.5)
    public private(set) var scopes: ScopeData?
    public var probe: PixelProbe?
    public private(set) var saveError: String?
    /// True on the clean engine: every per-pixel module can be limited to part of the picture by a local mask.
    public private(set) var localMasks = false
    /// One sentence per module whose algorithm differs from the one that made the saved edits (empty when they match).
    public private(set) var versionNotices: [String] = []
    /// Set when the image's sidecar could not be read (a newer format, or damaged): the file is left alone and not saved over.
    private var sidecarLocked: String?
    /// The history, step and algorithm versions as they are on disk (or as opened with no sidecar): a save that would
    /// write the same thing is skipped, so merely opening a photo never re-stamps its sidecar with this app's versions.
    private var lastSaved: (history: [HistoryItem], index: Int, layers: [MaskLayer])?
    private var loadedAlgorithms: [String: Int]?
    private var loadedEdits: EditMap = [:]

    private let engine: any PhotoEngine
    private var rendering = false
    private var wantsRender = false
    private var renderGeneration = 0
    private var renderStarted = ContinuousClock.now
    private var cancelScheduled = false
    /// Renders stopped because a newer edit superseded them; for the self-test.
    public private(set) var canceledRenders = 0

    /// A slider is held. While it moves, an edit whose full render is slow is shown as a
    /// reduced-scale draft; releasing it, or holding it still for `settleAfter`, renders
    /// the full frame the same way a single edit would.
    public private(set) var dragging = false
    /// The frame on screen is a draft, not the exact render of the current edits.
    public private(set) var frameIsDraft = false
    static let draftScale = 0.5
    static let settleAfter: Duration = .milliseconds(150)
    /// Below this a full render keeps up with a drag, and a draft would cost more than it
    /// saves: the first one at a new scale recomputes the whole pipe.
    static let slowRender: Duration = cancelAfter
    private var lastEdit = ContinuousClock.now
    private var lastFullRender: Duration = .zero
    private var settleScheduled = false
    private var renderIsDraft = false
    /// A superseded render that would finish within this is let through, so a drag keeps
    /// showing frames; one that runs longer is stopped so the newest edit goes next.
    static let cancelAfter: Duration = .milliseconds(100)
    private var scopeGeneration = 0
    private var scopeJobs = 0
    private var saveTask: Task<Void, Never>?
    public let backingScale: Double = Double(NSScreen.main?.backingScaleFactor ?? 2)

    public init(engine: any PhotoEngine = Engine()) {
        self.engine = engine
        // the screen's headroom follows its brightness and whether a layer asks for extended range: when it moves while the HDR preview is on,
        // the frame is rendered again for the new peak
        headroomObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hdrPreview, self.hdrAvailable, abs(self.previewPeak - self.lastPresentedPeak) > 0.05 else { return }
                self.requestRender()
            }
        }
    }
    private var headroomObserver: NSObjectProtocol?
    /// The peak the last presented frame was rendered for.
    private var lastPresentedPeak = 1.0

    /// For layout checks and previews: a model that already holds a picture and modules.
    public static func preview(image: CGImage, fileName: String, modules: [ModuleInfo] = []) -> DarkroomModel {
        let m = DarkroomModel()
        m.frame = image
        m.fileName = fileName
        m.status = "\(image.width) x \(image.height)"
        m.modules = modules
        m.scopes = ScopeData.measure(image)
        return m
    }

    // MARK: lifecycle

    public func bootstrap(openingFirstArgument: Bool = true) async {
        let env = ProcessInfo.processInfo.environment
        let prefix = URL(fileURLWithPath: env["DT_PREFIX"] ?? "/Users/Chief/darktable/build/install")
        let home = FileManager.default.homeDirectoryForCurrentUser
        do {
            try await engine.start(
                prefix: prefix,
                configDir: env["DARKROOM_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".config/darktable-fork"),
                cacheDir: env["DARKROOM_CACHE_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".cache/darktable-fork"))
        } catch {
            status = "Engine did not start: \(error)"
            return
        }
        // a bare path argument would be taken by AppKit as a document-open request and
        // suppress the window, so the launch file comes from --open=<path> or DARKROOM_OPEN
        if openingFirstArgument, let launch = Self.launchPath(env: env) {
            await open(path: launch)
        }
    }

    public func open(path: String) async {
        await flushSave()
        filePath = path
        fileName = URL(fileURLWithPath: path).lastPathComponent
        exifLine = Self.exif(of: path)
        status = "Developing…"
        frame = nil
        frameTexture = nil
        frameFullSize = nil
        scopes = nil
        center = CGPoint(x: 0.5, y: 0.5)
        zoom = .fit
        showingOriginal = false
        showingSnapshot = false
        snapshotEdits = nil
        snapshotTime = nil

        do {
            try await engine.openSession(path: path, maxSide: Self.workingSize)
            modules = try await engine.sessionModules()
            localMasks = !(await engine.algorithmVersions()).isEmpty
            info = await engine.sessionInfo()
            outputSize = nil
            proOpen = Set(modules.filter { $0.operation == "tonecurve" }.map(\.id))
            // an explicit flip to "none" shows the sensor frame, so its size is the sensor's
            let sensorStack = [StackEntry(operation: "flip", params: ["orientation": .option("ORIENTATION_NONE")])]
            if let s = try? await engine.sessionOutputSize(stack: sensorStack), let camera = info?.cameraOrientation {
                geometryBase = (SIMD2(Double(s.width), Double(s.height)), Orientation(value: camera))
            } else {
                geometryBase = nil
            }
            // the embedded preview shows at once as a draft; the full render replaces it.
            // A missing preview is not an error: the open continues and waits for the render.
            if let preview = try? await engine.sessionPreview() {
                frame = preview.image
                frameTexture = nil
                frameFullSize = nil
                frameIsDraft = true
            }
        } catch {
            status = "\(error)"
            // nothing is open: the previous photo's edits must not be saved over this path's sidecar by the next flush
            saveTask?.cancel()
            filePath = nil
            sidecarLocked = nil
            versionNotices = []
            history = [HistoryItem(label: "original", detail: "", edits: [:])]
            historyIndex = 0
            edits = [:]
            lastSaved = nil
            maskLayers = []
            return
        }

        sidecarLocked = nil
        versionNotices = []
        let loaded = Sidecar.read(for: path)
        if case .loaded(let s) = loaded {
            history = s.history
            let folded = Self.foldAliases(&history, into: modules)
            historyIndex = min(max(0, s.index), s.history.count - 1)
            let known = Set(modules.map(\.id))
            edits = history[historyIndex].edits.filter { known.contains($0.key) }
            versionNotices = s.versionNotices(current: await engine.algorithmVersions())
            lastSaved = (s.history, s.index, s.layers ?? [])
            maskLayers = s.layers ?? []
            loadedAlgorithms = s.algorithms
            loadedEdits = history[historyIndex].edits
            if folded > 0 { versionNotices.insert("\(folded) older module\(folded == 1 ? " was" : "s were") folded into the one that replaced \(folded == 1 ? "it" : "them") (see the manual)", at: 0) }
            if let first = versionNotices.first { status = versionNotices.count == 1 ? first : "\(first) (and \(versionNotices.count - 1) more)" }
        } else {
            if case .unreadable(let why) = loaded {
                sidecarLocked = why
                saveError = "Edits are not saved for this photo: \(why). The file was left untouched."
            }
            history = [HistoryItem(label: "original", detail: "", edits: [:])]
            historyIndex = 0
            edits = [:]
            lastSaved = (history, 0, [])
            maskLayers = []
            loadedAlgorithms = nil
            loadedEdits = [:]
        }

        selectedID = modules.first { $0.operation == "exposure" }?.id ?? modules.first?.id
        if let sel = selectedID, let m = modules.first(where: { $0.id == sel }) { await loadSchema(for: m) }
        requestRender()
    }

    /// A sidecar that names a module folded into another (the merge of 2026-10-22, `CIEngineProbe.aliases`) is carried over: in every
    /// history step the edit moves onto the survivor's id with its parameters mapped, so the picture is what it was and the panel shows
    /// the module that exists. A survivor already edited in that step takes the fold as its next instance. Returns how many ids moved.
    static func foldAliases(_ history: inout [HistoryItem], into modules: [ModuleInfo]) -> Int {
        let aliases = CIEngineProbe.aliases
        guard !aliases.isEmpty else { return 0 }
        var moved = Set<String>()
        for i in history.indices {
            var edits = history[i].edits
            for (id, edit) in history[i].edits {
                let parts = id.split(separator: "#", maxSplits: 1).map(String.init)
                guard parts.count == 2, let a = aliases[parts[0]] else { continue }
                edits[id] = nil
                var folded = edit
                folded.params = a.map(edit.params)
                let target = "\(a.survivor)#\(parts[1])"
                if var own = edits[target] {
                    // the survivor was edited in this step too: the fold joins it, its own values winning where both set a control
                    own.params.merge(folded.params) { mine, _ in mine }
                    own.blend.merge(folded.blend) { mine, _ in mine }
                    own.enabled = (own.enabled ?? false) || (folded.enabled ?? false) ? true : own.enabled
                    own.inPanel = own.inPanel ?? folded.inPanel
                    edits[target] = own
                } else {
                    edits[target] = folded
                }
                moved.insert(id)
            }
            history[i].edits = edits
        }
        return moved.count
    }

    // MARK: module list

    private var stageAnchors: (demosaic: Int, tone: Int) {
        let demosaic = modules.first { $0.operation == "demosaic" }?.iopOrder ?? Int.min
        let tone = modules.first { ["filmicrgb", "sigmoid", "agx"].contains($0.operation) }?.iopOrder ?? Int.max
        return (demosaic, tone)
    }

    public func stage(of m: ModuleInfo) -> Stage {
        let a = stageAnchors
        if m.iopOrder <= a.demosaic { return .raw }
        if m.iopOrder <= a.tone { return .scene }
        return .display
    }

    public func isEnabled(_ m: ModuleInfo) -> Bool { edits[m.id]?.enabled ?? m.enabled }

    public func isEdited(_ m: ModuleInfo) -> Bool {
        guard let e = edits[m.id] else { return false }
        return e.changesPicture
    }

    public var moduleRows: [ModuleRow] {
        let q = moduleQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return modules.compactMap { m in
            if m.deprecated && !showDeprecated && !isEnabled(m) { return nil }
            let on = isEnabled(m)
            if activeOnly && !on { return nil }
            if !q.isEmpty,
               !m.name.lowercased().contains(q),
               !m.operation.lowercased().contains(q),
               !m.multiName.lowercased().contains(q) { return nil }
            return ModuleRow(module: m, stage: stage(of: m), enabled: on, edited: isEdited(m))
        }
    }

    public var selectedModule: ModuleInfo? { modules.first { $0.id == selectedID } }

    public func select(_ m: ModuleInfo) {
        selectedID = m.id
        Task { await loadSchema(for: m) }
    }

    public func loadSchema(for m: ModuleInfo) async {
        guard m.haveIntrospection, schemas[m.operation] == nil else { return }
        if let s = try? await engine.schema(for: m.operation) { schemas[m.operation] = s }
    }

    // MARK: parameters

    public func schema(for m: ModuleInfo) -> ModuleSchema? { schemas[m.operation] }

    public func base(_ m: ModuleInfo, _ f: FieldSchema) -> ParamValue {
        m.params[f.name] ?? f.defaultValue
    }

    public func value(_ m: ModuleInfo, _ f: FieldSchema) -> ParamValue {
        edits[m.id]?.params[f.name] ?? base(m, f)
    }

    public func isChanged(_ m: ModuleInfo, _ f: FieldSchema) -> Bool {
        edits[m.id]?.params[f.name] != nil
    }

    /// The label a step gets: "exposure", or "color balance rgb · skin".
    private func title(_ m: ModuleInfo) -> String { m.title }

    /// A control that shows nothing while another of its module's controls is at zero: split toning's shadows hue is
    /// invisible until shadows saturation is above zero, a colour filter's hue until its strength is. Dragging the
    /// trigger wakes the sleeper to `wake` in the same history step, so the slider the user moves shows on the picture.
    /// A trigger of "*" is any control of the module but the sleeper. Defaults stay the identity (the goldens hold).
    static let wakes: [String: [(trigger: String, sleeper: String, wake: Double)]] = [
        "splittoning": [("shadows_hue", "shadows_saturation", 0.5), ("highlights_hue", "highlights_saturation", 0.5)],
        "monochrome": [("filter_hue", "filter_strength", 0.5), ("filter_hue", "intensity", 1), ("filter_strength", "intensity", 1)],
        "gradientmap": [("*", "strength", 0.5), ("mids_hue", "mids_sat", 0.5)],
        "warmth": [("hue", "density", 0.5), ("preserve", "density", 0.5)],
        "surfaceblur": [("hue", "amount", 0.5), ("width", "amount", 0.5), ("range", "amount", 0.5)],
        "bloom": [("*", "strength", 0.5)],
        "defringe": [("*", "strength", 0.5)],
    ]

    /// A line under a control whose effect is easy to miss, in the user's words (the manual says the same).
    static let hints: [String: String] = [
        "denoiseprofile.chroma": "colour noise only: shows on high-ISO photos, not on a clean one",
        "denoiseprofile.luma": "grain in the brightness; look at the shadows at 100%",
    ]
    public func hint(_ m: ModuleInfo, _ f: FieldSchema) -> String? { Self.hints["\(m.operation).\(f.name)"] }

    /// The controls `f` would wake (each at zero now) when it moves; empty when it moves on its own.
    public func sleepers(_ m: ModuleInfo, _ f: FieldSchema) -> [FieldSchema] {
        guard let rules = Self.wakes[m.operation], let fields = schemas[m.operation]?.fields else { return [] }
        var out: [FieldSchema] = []
        for r in rules where r.trigger == f.name || (r.trigger == "*" && f.name != r.sleeper) {
            guard let s = fields.first(where: { $0.name == r.sleeper }), !out.contains(where: { $0.name == s.name }),
                  (value(m, s).double ?? 0) == 0 else { continue }
            out.append(s)
        }
        return out
    }

    public func setParam(_ m: ModuleInfo, _ f: FieldSchema, to v: ParamValue) {
        var value = v
        if case .number(var d) = v {
            if f.hasUsableRange { d = min(max(d, f.min), f.max) }
            if f.kind == .int { d = d.rounded() }
            value = .number(d)
        }
        var e = edits[m.id] ?? ModuleEdit()
        // editing a module that was taken out of Pro's panel brings it back, as a fresh start (switched on below)
        if e.inPanel == false { e.inPanel = nil; e.enabled = nil }
        if value == base(m, f) { e.params[f.name] = nil } else { e.params[f.name] = value }
        // a hue moved while its strength sleeps at zero: wake the strength too, in this same step
        if value != base(m, f), let rules = Self.wakes[m.operation] {
            for s in sleepers(m, f) {
                let wake = rules.first { $0.sleeper == s.name }?.wake ?? 0.5
                let w = ParamValue.number(min(max(wake, s.min), s.max))
                e.params[s.name] = w == base(m, s) ? nil : w
            }
        }
        // changing a control on a module that is off turns it on, like the darkroom does
        if !m.enabled, e.enabled == nil, !e.params.isEmpty, !m.hideEnableButton { e.enabled = true }
        commit(id: m.id, edit: e, label: title(m), detail: "\(f.label): \(describe(value, f))",
               target: "\(m.id).\(f.name)")
    }

    public func resetParam(_ m: ModuleInfo, _ f: FieldSchema) {
        setParam(m, f, to: base(m, f))
    }

    public func setEnabled(_ m: ModuleInfo, _ on: Bool) {
        var e = edits[m.id] ?? ModuleEdit()
        e.enabled = (on == m.enabled) ? nil : on
        commit(id: m.id, edit: e, label: title(m), detail: on ? "enabled" : "disabled",
               target: "\(m.id).enabled")
    }

    public func toggleEnabled(_ m: ModuleInfo) { setEnabled(m, !isEnabled(m)) }

    public func resetModule(_ m: ModuleInfo) {
        // a reset keeps the module where it is in Pro's panel
        var e = ModuleEdit()
        e.inPanel = edits[m.id]?.inPanel
        commit(id: m.id, edit: e, label: title(m), detail: "reset", target: nil)
    }

    /// Pro's Modules menu: in adds the module to the panel switched on; out takes it out with its edits cleared and,
    /// when it is on by default, switched off, so it no longer applies. Always a change, so always a history step.
    func setInPanel(_ m: ModuleInfo, _ inside: Bool) {
        var e = inside ? (edits[m.id] ?? ModuleEdit()) : ModuleEdit()
        e.inPanel = inside
        let wantOn = inside
        if !m.hideEnableButton { e.enabled = (wantOn == m.enabled) ? nil : wantOn }
        commit(id: m.id, edit: e, label: title(m), detail: inside ? "added to the panel" : "taken out of the panel", target: nil)
    }

    // MARK: blend

    private func blendBase(_ m: ModuleInfo, _ key: String) -> ParamValue? {
        guard let b = m.blend else { return nil }
        switch key {
        case "mask_mode": return .number(Double(b.maskMode))
        case "blend_mode": return .number(Double(b.blendMode))
        case "reverse": return .bool(b.reverse)
        case "opacity": return .number(b.opacity)
        case "blend_parameter": return .number(b.blendParameter)
        case "feathering_radius": return .number(b.featheringRadius)
        case "blur_radius": return .number(b.blurRadius)
        case "contrast": return .number(b.contrast)
        case "brightness": return .number(b.brightness)
        default: return nil
        }
    }

    public func blendValue(_ m: ModuleInfo, _ key: String) -> ParamValue? {
        edits[m.id]?.blend[key] ?? blendBase(m, key)
    }

    // MARK: painted and detected masks

    private static func newLayerID() -> String { String(UUID().uuidString.lowercased().prefix(8)) }

    /// The layer a module's mask reads, if it reads one.
    public func maskLayer(for m: ModuleInfo) -> MaskLayer? {
        guard let ref = blendValue(m, "mask_raster")?.option else { return nil }
        let id = String(ref.split(separator: ".").first ?? "")
        return maskLayers.first { $0.id == id }
    }

    /// How many of a brush layer's strokes the module's edit counts.
    private func strokeCount(_ m: ModuleInfo) -> Int {
        Int((blendValue(m, "mask_raster")?.option ?? "").split(separator: ".").last ?? "") ?? 0
    }

    /// Whether strokes can be placed on the picture as shown: fit zoom, and no crop, straighten or flip that would move the
    /// picture away from the upright photo the masks are drawn on.
    public var canPaint: Bool {
        zoom == .fit && ["crop", "ashift", "flip"].allSatisfy { op in !modules.filter { $0.operation == op }.contains { edits[$0.id]?.changesPicture == true } }
    }

    /// Points the module at a layer (revision `rev`): kind 5, its own picture, the shared settings kept. One history step.
    private func attach(_ layer: MaskLayer, rev: Int, to m: ModuleInfo, detail: String) {
        var e = edits[m.id] ?? ModuleEdit()
        let shared: Set<String> = ["mask_feather", "mask_invert", "mask_refine"]
        for k in Array(e.blend.keys) where k.hasPrefix("mask_") && !shared.contains(k) { e.blend[k] = nil }
        e.blend["mask_mode"] = .number(2)
        e.blend["mask_kind"] = .number(5)
        e.blend["mask_raster"] = .option("\(layer.id).\(rev)")
        if !m.enabled, e.enabled == nil { e.enabled = true }
        commit(id: m.id, edit: e, label: title(m), detail: detail, target: nil)
    }

    /// A new empty brush layer for the module, ready to paint on (the mask is shown while painting).
    public func startBrush(_ m: ModuleInfo) {
        let n = maskLayers.filter { $0.kind == .brush }.count + 1
        let layer = MaskLayer(id: Self.newLayerID(), name: "brush \(n)", kind: .brush)
        maskLayers.append(layer)
        attach(layer, rev: 0, to: m, detail: "mask: brush")
        paintModuleID = m.id
        maskShowID = m.id
    }

    /// One more stroke on the module's brush layer. A stroke after an undo cuts the undone strokes off first.
    public func addStroke(_ stroke: BrushStroke, to m: ModuleInfo) {
        guard let layer = maskLayer(for: m), layer.kind == .brush, let i = maskLayers.firstIndex(where: { $0.id == layer.id }) else { return }
        maskLayers[i].strokes = Array(layer.strokes.prefix(strokeCount(m))) + [stroke]
        attach(maskLayers[i], rev: maskLayers[i].strokes.count, to: m, detail: stroke.erase ? "erase" : "brush stroke")
    }

    /// A stroke from points on the shown picture (normalised 0...1, y down) with the current brush.
    public func paintStroke(_ points: [CGPoint]) {
        guard let id = paintModuleID, let m = modules.first(where: { $0.id == id }), canPaint, !points.isEmpty else { return }
        let p = points.map { SIMD2(min(max(Double($0.x), 0), 1), min(max(Double($0.y), 0), 1)) }
        addStroke(BrushStroke(points: p, radius: brushRadius, softness: brushSoftness, flow: brushFlow, erase: brushErase), to: m)
    }

    /// Starts the module's brush over with an empty layer (the old one stays in the history).
    public func clearBrush(_ m: ModuleInfo) { startBrush(m) }

    /// Finds `kind` in the photo with Vision (on this Mac) and points the module's mask at it.
    public func detect(_ kind: VisionMasks.Kind, for m: ModuleInfo) async {
        guard let path = filePath, maskBusy == nil else { return }
        maskBusy = "Finding the \(kind.title)…"
        defer { maskBusy = nil }
        // the upright picture: the camera's embedded preview (orientation applied), else a small developed render
        let image: CGImage?
        if let preview = EmbeddedPreview.read(path: path, maxSide: 1200) { image = preview } else { image = try? await engine.render(path: path, maxSide: 1200, stack: []).image }
        guard let image else { status = "Cannot read the picture to find the \(kind.title)"; return }
        let found: VisionMasks.Picture?
        do { found = try await Task.detached(priority: .userInitiated) { try VisionMasks.detect(kind, in: image) }.value } catch {
            status = "Finding the \(kind.title) failed: \(error.localizedDescription)"; return
        }
        guard let found, filePath == path else { if found == nil { status = "No \(kind.title) found in this photo" }; return }
        let layer = MaskLayer(id: Self.newLayerID(), name: kind.title, kind: MaskLayerKind(kind), strokes: [], picture: nil)
        var stored = layer
        stored.picture = "\(layer.id).png"
        do { try MaskFiles.write(found.pixels, width: found.width, height: found.height, name: stored.picture!, for: path) } catch {
            status = "Could not save the \(kind.title) mask: \(error.localizedDescription)"; return
        }
        rasterCache["\(stored.id).0"] = MaskPicture(id: "\(stored.id).0", width: found.width, height: found.height, pixels: found.pixels)
        maskLayers.append(stored)
        attach(stored, rev: 0, to: m, detail: "mask: \(kind.title)")
        maskShowID = m.id
        status = "\(kind.title.capitalized) found: \(Int((found.coverage * 100).rounded()))% of the picture"
    }

    /// The picture a mask reference names, made (brush) or read (detected) the first time and kept.
    private func picture(forRef ref: String) -> MaskPicture? {
        if let hit = rasterCache[ref] { return hit }
        let parts = ref.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let layer = maskLayers.first(where: { $0.id == parts[0] }) else { return nil }
        let made: MaskPicture?
        if layer.kind == .brush {
            let rev = max(0, min(Int(parts[1]) ?? 0, layer.strokes.count))
            let aspect = info.map { Double($0.processedWidth) / Double(max($0.processedHeight, 1)) } ?? 1.5
            let size = Brush.rasterSize(aspect: aspect)
            let r = Brush.rasterize(layer.strokes.prefix(rev), width: size.width, height: size.height, id: ref)
            made = MaskPicture(id: ref, width: r.width, height: r.height, pixels: r.pixels)
        } else if let file = layer.picture, let path = filePath, let p = MaskFiles.read(name: file, for: path) {
            made = MaskPicture(id: ref, width: p.width, height: p.height, pixels: p.pixels)
        } else { made = nil }
        if let made {
            if rasterCache.count > 32 { rasterCache.removeAll() }
            rasterCache[ref] = made
        }
        return made
    }

    /// Hands the engine the pictures the stack's raster masks name (only when the set changed).
    private func shipRasters(for entries: [StackEntry]) async {
        var pictures: [MaskPicture] = []
        for e in entries where e.blend["mask_mode"]?.double == 2 && e.blend["mask_kind"]?.double == 5 {
            if let ref = e.blend["mask_raster"]?.option, let p = picture(forRef: ref) { pictures.append(p) }
        }
        let ids = Set(pictures.map(\.id))
        guard ids != shippedRasterIDs else { return }
        shippedRasterIDs = ids
        await engine.setMaskRasters(pictures)
    }

    /// Picks how a module is limited: `mode` 0 off, 1 uniform (opacity only), 2 a local mask of `kind`. One history step.
    /// A kind change drops the old kind's own settings (they mean other things); feather, invert and edge refine stay.
    public func setMask(_ m: ModuleInfo, mode: Int, kind: MaskKind?) {
        var e = edits[m.id] ?? ModuleEdit()
        let shared: Set<String> = ["mask_feather", "mask_invert", "mask_refine"]
        for k in Array(e.blend.keys) where k.hasPrefix("mask_") && (mode == 0 || !shared.contains(k)) { e.blend[k] = nil }
        if mode != 0 {
            e.blend["mask_mode"] = .number(Double(mode))
            if let kind { e.blend["mask_kind"] = .number(Double(kind.rawValue)) }
        }
        if !m.enabled, e.enabled == nil, !e.blend.isEmpty { e.enabled = true }
        let name = mode == 0 ? "off" : (kind?.title ?? "uniform")
        commit(id: m.id, edit: e, label: title(m), detail: "mask: \(name)", target: nil)
    }

    public func setBlend(_ m: ModuleInfo, _ key: String, to v: ParamValue, detail: String) {
        var e = edits[m.id] ?? ModuleEdit()
        if v == blendBase(m, key) { e.blend[key] = nil } else { e.blend[key] = v }
        if !m.enabled, e.enabled == nil, !e.blend.isEmpty { e.enabled = true }
        commit(id: m.id, edit: e, label: title(m), detail: detail, target: "\(m.id).blend.\(key)")
    }

    // MARK: history

    private func commit(id: String, edit: ModuleEdit, label: String, detail: String, target: String?) {
        var next = edits
        if edit.isEmpty { next[id] = nil } else { next[id] = edit }
        guard next != edits else { return }
        edits = next

        let now = Date()
        // dragging a slider is one step, not hundreds
        if let t = target, historyIndex == history.count - 1, historyIndex > 0,
           history[historyIndex].target == t, now.timeIntervalSince(history[historyIndex].time) < 1.5 {
            history[historyIndex].edits = next
            history[historyIndex].detail = detail
            history[historyIndex].time = now
        } else {
            history = Array(history[0...historyIndex])
            history.append(HistoryItem(label: label, detail: detail, edits: next, target: target, time: now))
            historyIndex = history.count - 1
        }
        changed()
    }

    /// Folds every history step `body` makes into one, so a single action by the user (a look,
    /// a Simple slider that writes two parameters) undoes in one press. Repeated drags of the same
    /// `target` within 1.5 s merge into that one step, as a drag on a Pro slider does.
    public func grouped(_ label: String, target: String, _ body: () -> Void) {
        let start = historyIndex
        let merging = start > 0 && start == history.count - 1 && history[start].target == target
            && Date().timeIntervalSince(history[start].time) < 1.5
        body()
        guard historyIndex > start else { return }
        let last = history[historyIndex]
        history.removeSubrange((start + 1)...historyIndex)
        if merging {
            history[start].edits = last.edits
            history[start].detail = last.detail
            history[start].time = Date()
            historyIndex = start
        } else {
            history.append(HistoryItem(label: label, detail: last.detail, edits: last.edits, target: target, time: Date()))
            historyIndex = history.count - 1
        }
    }

    public var canUndo: Bool { historyIndex > 0 }
    public var canRedo: Bool { historyIndex < history.count - 1 }

    public func undo() { if canUndo { jump(to: historyIndex - 1) } }
    public func redo() { if canRedo { jump(to: historyIndex + 1) } }

    public func jump(to index: Int) {
        guard history.indices.contains(index), index != historyIndex else { return }
        historyIndex = index
        edits = history[index].edits
        changed()
    }

    // MARK: snapshot

    public func takeSnapshot() {
        snapshotEdits = edits
        snapshotTime = Date()
    }

    public func clearSnapshot() {
        snapshotEdits = nil
        snapshotTime = nil
        showingSnapshot = false
    }

    // MARK: view

    public var displayScale: Double {
        switch zoom {
        case .fit: return 0
        case .actual: return 1
        case .double: return 2
        }
    }

    public func pan(byFraction d: CGSize) {
        guard zoom != .fit else { return }
        setCenter(CGPoint(x: center.x + d.width, y: center.y + d.height))
    }

    public func setCenter(_ p: CGPoint) {
        center = CGPoint(x: min(max(0, p.x), 1), y: min(max(0, p.y), 1))
        requestRender()
    }

    /// Sample the displayed frame; x and y are in the frame's own pixels.
    public func sample(x: Int, y: Int) -> PixelProbe? {
        guard let f = frame, x >= 0, y >= 0, x < f.width, y < f.height,
              let data = f.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
        let o = y * f.bytesPerRow + x * 4
        return PixelProbe(x: x, y: y, r: Int(p[o + 2]), g: Int(p[o + 1]), b: Int(p[o]))
    }

    // MARK: stack and rendering

    /// `overlay` adds the render-only flag that draws the shown module's mask over the picture (the screen render, never an export).
    public func stack(for map: EditMap, overlay: Bool = false) -> [StackEntry] {
        let byID = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0) })
        return map.compactMap { id, e -> (Int, StackEntry)? in
            guard !e.isEmpty, let m = byID[id] else { return nil }
            var blend = e.blend
            if overlay, id == maskShowID, blend["mask_mode"]?.double == 2 { blend["mask_show"] = .number(1) }
            return (m.iopOrder, StackEntry(
                operation: m.operation, multiPriority: m.multiPriority,
                params: e.params, blend: blend, enabled: e.enabled ?? m.enabled))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    public func buildStack() -> [StackEntry] { stack(for: edits) }

    private func changed() {
        lastEdit = ContinuousClock.now
        requestRender()
        scheduleSave()
    }

    private var shownEdits: EditMap {
        if showingOriginal { return [:] }
        if showingSnapshot, let s = snapshotEdits { return s }
        return edits
    }

    public func requestRender() {
        wantsRender = true
        guard !rendering else { supersede(); return }
        Task { await renderLoop() }
    }

    /// Called by sliders as they are grabbed and let go.
    public func setDragging(_ on: Bool) {
        guard on != dragging else { return }
        dragging = on
        if !on, frameIsDraft { requestRender() }
    }

    private var wantsDraft: Bool {
        dragging && zoom == .fit && info != nil && lastFullRender >= Self.slowRender
            && ContinuousClock.now - lastEdit < Self.settleAfter
    }

    /// After a draft, render the full frame once the slider has been still for `settleAfter`.
    private func scheduleSettle() {
        guard !settleScheduled else { return }
        settleScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.settleAfter)
            guard let self else { return }
            self.settleScheduled = false
            guard self.frameIsDraft, !self.rendering, !self.wantsRender else { return }
            if ContinuousClock.now - self.lastEdit >= Self.settleAfter { self.requestRender() } else { self.scheduleSettle() }
        }
    }

    /// The render in flight is stale: stop it once it has run `cancelAfter`. A draft is
    /// let through, as it is the frame a drag gets to see.
    private func supersede() {
        guard !cancelScheduled, !renderIsDraft else { return }
        let ran = ContinuousClock.now - renderStarted
        if ran >= Self.cancelAfter {
            engine.cancelRender()
            return
        }
        cancelScheduled = true
        let gen = renderGeneration
        Task { [weak self] in
            try? await Task.sleep(for: Self.cancelAfter - ran)
            guard let self else { return }
            self.cancelScheduled = false
            guard self.rendering, self.wantsRender else { return }
            // a newer render started meanwhile and is itself superseded: time that one
            if self.renderGeneration == gen { self.engine.cancelRender() } else { self.supersede() }
        }
    }

    /// Returns once no render is running or queued. For headless callers and tests.
    public func settle() async {
        while rendering || wantsRender || settleScheduled || scopeJobs > 0 { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func renderLoop() async {
        guard !rendering else { return }
        rendering = true
        defer { rendering = false }

        while wantsRender {
            wantsRender = false
            guard filePath != nil else { return }
            let entries = stack(for: shownEdits, overlay: true)
            await shipRasters(for: entries)
            // geometry changes the size the region maths below works in
            outputSize = try? await engine.sessionOutputSize(stack: entries)
            renderGeneration += 1
            renderStarted = ContinuousClock.now
            let draft = wantsDraft
            renderIsDraft = draft
            do {
                let result: RenderedFrame
                var presented: PresentedFrame?
                if presentsTexture {
                    lastPresentedPeak = previewPeak
                    await engine.setPreviewPeak(previewPeak)
                    if zoom == .fit || info == nil {
                        presented = try await engine.sessionRenderPresentable(stack: entries, scale: draft ? Self.draftScale : 1)
                    } else {
                        let r = region()
                        presented = try await engine.sessionRenderRegionPresentable(
                            stack: entries, scale: r.scale, x: r.x, y: r.y, width: r.w, height: r.h)
                    }
                }
                if testCard, let p = presented, let card = TestCard.frame(device: p.texture.device, peak: previewPeak) { presented = card }
                if let p = presented {
                    result = RenderedFrame(image: p.thumbnail, width: p.width, height: p.height, milliseconds: p.milliseconds)
                } else if zoom == .fit || info == nil {
                    result = try await engine.sessionRender(stack: entries, scale: draft ? Self.draftScale : 1)
                } else {
                    let r = region()
                    result = try await engine.sessionRenderRegion(
                        stack: entries, scale: r.scale, x: r.x, y: r.y, width: r.w, height: r.h)
                }
                frame = result.image
                frameTexture = presented
                frameFullSize = presented.map { CGSize(width: $0.width, height: $0.height) }
                if presented != nil { frameSerial += 1 }
                frameIsDraft = draft
                lastMilliseconds = result.milliseconds
                if draft {
                    scheduleSettle()
                } else {
                    lastFullRender = .milliseconds(result.milliseconds)
                    status = "\(result.width) x \(result.height)"
                    if !showingOriginal && maskShowID == nil && !showClipping { measureScopes(result.image) }   // the red overlay is not part of the picture
                }
            } catch is RenderCanceled {
                // superseded: wantsRender is set and the loop renders the newest edit
                canceledRenders += 1
                // a full render cut short already ran long enough to call it slow
                if !draft { lastFullRender = max(lastFullRender, ContinuousClock.now - renderStarted) }
            } catch {
                status = "\(error)"
            }
        }
    }

    private func region() -> (scale: Double, x: Int, y: Int, w: Int, h: Int) {
        let scale = displayScale
        let imgW = Double(imageSize?.width ?? 1) * scale
        let imgH = Double(imageSize?.height ?? 1) * scale
        let w = max(1, min(Int(viewport.width * backingScale), Int(imgW)))
        let h = max(1, min(Int(viewport.height * backingScale), Int(imgH)))
        let x = Int((center.x * imgW) - Double(w) / 2)
        let y = Int((center.y * imgH) - Double(h) / 2)
        return (scale, min(max(0, x), max(0, Int(imgW) - w)), min(max(0, y), max(0, Int(imgH) - h)), w, h)
    }

    private func measureScopes(_ image: CGImage) {
        scopeGeneration += 1
        scopeJobs += 1
        let gen = scopeGeneration
        Task { [weak self] in
            // measured off the main actor; only the newest frame's result is kept
            let data = await Task.detached(priority: .utility) {
                ScopeData.measure(image, stride: 3)
            }.value
            guard let self else { return }
            self.scopeJobs -= 1
            if self.scopeGeneration == gen { self.scopes = data }
        }
    }

    // MARK: save

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await self?.flushSave()
        }
    }

    public func flushSave() async {
        saveTask?.cancel()
        guard let path = filePath else { return }
        // a sidecar this app could not read is somebody's edits (a newer app's): never write over it
        if let why = sidecarLocked { saveError = "Edits are not saved for this photo: \(why). The file was left untouched."; return }
        if let last = lastSaved, last.history == history, last.index == historyIndex, last.layers == maskLayers { return }   // nothing to write
        let hasEdits = history.count > 1
        let url = Sidecar.url(for: path)
        do {
            if hasEdits {
                var s = Sidecar(history: history, index: historyIndex, layers: maskLayers.isEmpty ? nil : maskLayers)
                // this app's versions, except for a module whose edit is the one that was loaded: it keeps the version
                // it was made with, so a notice about changed maths does not vanish by merely re-saving
                var versions = await engine.algorithmVersions()
                if versions.isEmpty { versions = loadedAlgorithms ?? [:] } else {
                    for (id, edit) in edits where loadedEdits[id] == edit {
                        let op = String(id.split(separator: "#").first ?? "")
                        if let was = loadedAlgorithms?[op] { versions[op] = was }
                    }
                }
                s.algorithms = versions.isEmpty ? nil : versions
                try s.save(for: path)
                lastSaved = (history, historyIndex, maskLayers)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                lastSaved = (history, historyIndex, maskLayers)
            }
            saveError = nil
        } catch {
            saveError = "Could not save edits: \(error.localizedDescription)"
        }
    }

    // MARK: export

    /// Full-size JPEG of the current edit. The bound is the sensor's own long side, so
    /// darktable's upscale flag cannot enlarge the picture beyond the original.
    public func export(to url: URL, hdr: Bool = false) async {
        guard let path = filePath else { return }
        status = "Exporting…"
        let bound = Self.longSide(of: path) ?? 4096
        do {
            if hdr {
                // the engine's JPEG with an HDR gain map; an engine that cannot make one says so and the normal export runs
                await shipRasters(for: buildStack())
                if let data = try await engine.exportHDRJPEG(path: path, maxSide: bound, stack: buildStack(), headroom: 4) {
                    try data.write(to: url, options: .atomic)
                    status = "Exported \(url.lastPathComponent) with an HDR gain map"
                    requestRender()
                    return
                }
            }
            await shipRasters(for: buildStack())
            let result = try await engine.exportRender(path: path, maxSide: bound, stack: buildStack())
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw EngineError("cannot create \(url.lastPathComponent)") }
            CGImageDestinationAddImage(
                dest, result.image,
                [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw EngineError("cannot write \(url.lastPathComponent)") }
            status = "Exported \(result.width) x \(result.height) to \(url.lastPathComponent)"
        } catch {
            status = "Export failed: \(error)"
        }
        requestRender()
    }

    // MARK: helpers

    static func launchPath(env: [String: String]) -> String? {
        if let p = env["DARKROOM_OPEN"], !p.isEmpty { return p }
        for a in CommandLine.arguments.dropFirst() where a.hasPrefix("--open=") {
            return String(a.dropFirst("--open=".count))
        }
        return nil
    }

    private func describe(_ v: ParamValue, _ f: FieldSchema) -> String {
        switch v {
        case .number(let d): return f.kind == .int ? String(Int(d)) : String(format: "%.3g", d)
        case .bool(let b): return b ? "on" : "off"
        case .option(let s): return f.options.first { $0.name == s }?.label ?? s
        }
    }

    private static func properties(of path: String) -> [CFString: Any]? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    }

    private static func longSide(of path: String) -> Int? {
        guard let p = properties(of: path),
              let w = p[kCGImagePropertyPixelWidth] as? Int,
              let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(w, h)
    }

    static func exif(of path: String) -> String {
        guard let p = properties(of: path), let ex = p[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return "" }
        var parts: [String] = []
        if let iso = (ex[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { parts.append("ISO \(iso)") }
        if let f = ex[kCGImagePropertyExifFocalLength] as? Double { parts.append("\(Int(f.rounded())) mm") }
        if let a = ex[kCGImagePropertyExifFNumber] as? Double { parts.append(String(format: "f/%.1f", a)) }
        if let t = ex[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            parts.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded()))")
        }
        return parts.joined(separator: " · ")
    }
}
