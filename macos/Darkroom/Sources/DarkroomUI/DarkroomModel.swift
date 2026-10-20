import AppKit
import CoreGraphics
import DarkroomCore
import DarktableKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

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
@MainActor
@Observable
public final class DarkroomModel {
    public static let workingSize = 1600

    // image
    public private(set) var frame: CGImage?
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
    public var blendOpen = false

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
    }

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
                frameIsDraft = true
            }
        } catch {
            status = "\(error)"
            return
        }

        if let s = Sidecar.load(for: path) {
            history = s.history
            historyIndex = min(max(0, s.index), s.history.count - 1)
            let known = Set(modules.map(\.id))
            edits = history[historyIndex].edits.filter { known.contains($0.key) }
        } else {
            history = [HistoryItem(label: "original", detail: "", edits: [:])]
            historyIndex = 0
            edits = [:]
        }

        selectedID = modules.first { $0.operation == "exposure" }?.id ?? modules.first?.id
        if let sel = selectedID, let m = modules.first(where: { $0.id == sel }) { await loadSchema(for: m) }
        requestRender()
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

    func loadSchema(for m: ModuleInfo) async {
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

    public func stack(for map: EditMap) -> [StackEntry] {
        let byID = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0) })
        return map.compactMap { id, e -> (Int, StackEntry)? in
            guard !e.isEmpty, let m = byID[id] else { return nil }
            return (m.iopOrder, StackEntry(
                operation: m.operation, multiPriority: m.multiPriority,
                params: e.params, blend: e.blend, enabled: e.enabled ?? m.enabled))
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
            let entries = stack(for: shownEdits)
            // geometry changes the size the region maths below works in
            outputSize = try? await engine.sessionOutputSize(stack: entries)
            renderGeneration += 1
            renderStarted = ContinuousClock.now
            let draft = wantsDraft
            renderIsDraft = draft
            do {
                let result: RenderedFrame
                if zoom == .fit || info == nil {
                    result = try await engine.sessionRender(stack: entries, scale: draft ? Self.draftScale : 1)
                } else {
                    let r = region()
                    result = try await engine.sessionRenderRegion(
                        stack: entries, scale: r.scale, x: r.x, y: r.y, width: r.w, height: r.h)
                }
                frame = result.image
                frameIsDraft = draft
                lastMilliseconds = result.milliseconds
                if draft {
                    scheduleSettle()
                } else {
                    lastFullRender = .milliseconds(result.milliseconds)
                    status = "\(result.width) x \(result.height)"
                    if !showingOriginal { measureScopes(result.image) }
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
        let hasEdits = history.count > 1
        let url = Sidecar.url(for: path)
        do {
            if hasEdits {
                try Sidecar(history: history, index: historyIndex).save(for: path)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            saveError = nil
        } catch {
            saveError = "Could not save edits: \(error.localizedDescription)"
        }
    }

    // MARK: export

    /// Full-size JPEG of the current edit. The bound is the sensor's own long side, so
    /// darktable's upscale flag cannot enlarge the picture beyond the original.
    public func export(to url: URL) async {
        guard let path = filePath else { return }
        status = "Exporting…"
        let bound = Self.longSide(of: path) ?? 4096
        do {
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
