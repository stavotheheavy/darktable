import DarkroomCore
import DarktableKit
import SwiftUI

/// Pro mode's side panel holds the modules in use; the header's Modules menu puts them in or takes them out.
/// Two kinds of off, kept apart on purpose (owner's rule): the menu switch takes a module out of the panel and
/// stops applying it; the section's power button only turns its effect off, and the section stays with its settings.
extension DarkroomModel {
    /// The ten modules most edits use, first in the Modules menu. "Crop and straighten" is crop and ashift together.
    static let proCommon: [[String]] = [
        ["temperature"], ["exposure"], ["tonecurve"], ["zones"], ["colorbalancergb"],
        ["splittoning"], ["monochrome"], ["sharpen"], ["denoiseprofile"],
    ]
    /// The darktable engine has no zone exposure; its shadows and highlights stands in for it in the common ten.
    static let proCommonAlternates: [String: String] = ["zones": "shadhi"]
    /// Crop, straighten and the turn and flip: a tool in the header (CropTool.swift), not modules in the menu or the panel.
    static let geometryOperations: Set<String> = ["crop", "ashift", "flip"]
    /// A new photo starts with these in the panel, at neutral settings.
    public static let proBasics: Set<String> = ["temperature", "exposure", "tonecurve", "colorbalancergb", "display"]

    /// The menu's groups, by operation; anything not listed (darktable has many more) goes under Other.
    public static let proGroups: [(name: String, operations: Set<String>)] = [
        ("Tone", ["temperature", "exposure", "tonecurve", "rgbcurve", "rgblevels", "basecurve", "shadhi", "relight",
                  "zonesystem", "basicadj", "display", "toneequal", "filmicrgb", "sigmoid", "agx", "highlights",
                  "highlightrolloff", "lumabands", "hdrtone", "lumacurve", "scurve"]),
        ("Color", ["colorbalancergb", "channelmixer", "channelmixerrgb", "velvia", "vibrance", "colorize", "colorcontrast",
                   "colorcorrection", "splittoning", "monochrome", "primaries", "satcurvergb", "colorequal", "colisa",
                   "invert", "negadoctor", "colorzones", "lut3d", "gradientmap", "bleachbypass",
                   "channelcurves", "chromalimit", "warmth", "colorharmonizer", "selectivecolor"]),
        ("Detail", ["sharpen", "denoiseprofile", "bilat", "clahe", "atrous", "highpass", "lowpass", "blurs", "diffuse",
                    "nlmeans", "hotpixels", "rawdenoise", "defringe", "nlmeans", "bilateral", "surfaceblur", "lensblur", "motionblur", "radialblur", "diffuse", "mediandenoise", "deband"]),
        ("Geometry", ["flip", "ashift", "crop", "lens", "liquify", "retouch", "spots", "caradial", "distortion", "perspective"]),
        ("Effects", ["vignette", "bloom", "grain", "soften", "dither", "censorize", "lowlight", "graduated", "hazeremoval", "radiallight", "solarize", "tiltshift", "kuwahara", "emboss", "sketch", "halftone"]),
    ]

    /// The module behind an operation (the first instance).
    func proModule(_ operation: String) -> ModuleInfo? { modules.first { $0.operation == operation && $0.multiPriority == 0 } ?? modules.first { $0.operation == operation } }

    /// In the panel: what the Modules menu last said (stored with the edit, so undo, redo and the sidecar keep it);
    /// otherwise by default: a basic (its first instance), anything edited, or anything the engine applies that can
    /// be switched off (darktable turns several on by default, and the menu must match what is applied).
    public func inProPanel(_ m: ModuleInfo) -> Bool { inProPanel(m, edits) }

    /// The same question of an earlier (or later) state of the edits, for the panel's history order.
    func inProPanel(_ m: ModuleInfo, _ map: EditMap) -> Bool {
        if let decided = map[m.id]?.inPanel { return decided }
        if Self.proBasics.contains(m.operation) && m.multiPriority == 0 { return true }
        let e = map[m.id]
        let edited = e.map { !$0.params.isEmpty || !$0.blend.isEmpty || ($0.enabled != nil && $0.enabled != m.enabled) } ?? false
        return edited || ((e?.enabled ?? m.enabled) && !m.hideEnableButton)
    }

    /// Applied to the picture in this state of the edits: in the panel and switched on.
    private func live(_ m: ModuleInfo, _ map: EditMap) -> Bool {
        inProPanel(m, map) && (map[m.id]?.enabled ?? m.enabled) && !m.hideEnableButton
    }

    /// The history step (index) at which each module last went live, over the steps up to the current one. A module
    /// that was live from the start (a basic at import) has no step. Derived, so undo and redo keep the order honest.
    private var lastSwitchedOn: [String: Int] {
        var out: [String: Int] = [:]
        guard historyIndex > 0 else { return out }
        for i in 1...historyIndex {
            let prev = history[i - 1].edits, cur = history[i].edits
            // only modules whose edit changed in this step can have changed state
            for id in Set(prev.keys).union(cur.keys) where prev[id] != cur[id] {
                guard let m = modules.first(where: { $0.id == id }) else { continue }
                if !live(m, prev) && live(m, cur) { out[id] = i }
            }
        }
        return out
    }

    /// One panel entry per module, or per group of modules shown as one section (crop and straighten).
    public struct ProEntry: Identifiable {
        public let id: String
        public let name: String
        public let modules: [ModuleInfo]
        /// For rig ids: the operation, plus the instance number past the first (URL-safe, unique).
        var rigName: String { modules[0].multiPriority == 0 ? modules[0].operation : "\(modules[0].operation)-\(modules[0].multiPriority)" }
    }

    private func entry(for operations: [String]) -> ProEntry? {
        let ms = operations.compactMap { proModule($0) ?? Self.proCommonAlternates[$0].flatMap(proModule) }
        guard let first = ms.first else { return nil }
        return ProEntry(id: first.id, name: first.title, modules: ms)
    }

    /// The panel's sections: by `proPanelOrder`, the one switched on last first (then the ones live since import, in
    /// engine order), or all in the order the engine applies them.
    public var proPanelEntries: [ProEntry] {
        var seen = Set<String>(), out: [(Int, ProEntry)] = []
        for m in modules where inProPanel(m) && !seen.contains(m.id) && !Self.geometryOperations.contains(m.operation) {
            seen.insert(m.id)
            out.append((m.iopOrder, ProEntry(id: m.id, name: m.title, modules: [m])))
        }
        let pipeline = out.sorted { $0.0 < $1.0 }.map(\.1)
        guard proPanelOrder == .newest else { return pipeline }
        let steps = lastSwitchedOn
        func step(_ e: ProEntry) -> Int { e.modules.compactMap { steps[$0.id] }.max() ?? -1 }
        // a stable sort: newest step first; the ones without a step keep their pipeline order after them
        return pipeline.enumerated().sorted { a, b in
            let sa = step(a.element), sb = step(b.element)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    }

    /// Every section's effect on, or off, as one history step. The sections stay with their settings.
    public func setAllProEffects(_ on: Bool) {
        let targets = proPanelEntries.flatMap(\.modules).filter { !$0.hideEnableButton && isEnabled($0) != on }
        guard !targets.isEmpty else { return }
        grouped(on ? "All modules on" : "All modules off", target: "pro.all.\(history.count)") {
            for m in targets { setEnabled(m, on) }
        }
    }
    /// Whether All on / All off would change anything.
    public func canSetAllProEffects(_ on: Bool) -> Bool {
        proPanelEntries.flatMap(\.modules).contains { !$0.hideEnableButton && isEnabled($0) != on }
    }

    /// The Modules menu: the common ten first, then everything else by kind.
    public var proMenu: [(group: String, entries: [ProEntry])] {
        let common = Self.proCommon.compactMap(entry(for:))
        let commonOps = Set(Self.proCommon.flatMap { $0 })
        var groups: [(String, [ProEntry])] = [("Common", common)]
        // every other module, including second instances of a common one (they get their own entries)
        let rest = modules.filter { !(commonOps.contains($0.operation) && $0.multiPriority == 0) && !$0.deprecated && !Self.geometryOperations.contains($0.operation) }
        var used = Set<String>()
        for (name, ops) in Self.proGroups {
            let items = rest.filter { ops.contains($0.operation) }
            items.forEach { used.insert($0.id) }
            if !items.isEmpty { groups.append((name, items.map { ProEntry(id: $0.id, name: $0.title, modules: [$0]) })) }
        }
        let other = rest.filter { !used.contains($0.id) }
        if !other.isEmpty { groups.append(("Other", other.map { ProEntry(id: $0.id, name: $0.title, modules: [$0]) })) }
        return groups
    }

    public func inProPanel(_ e: ProEntry) -> Bool { e.modules.contains(where: inProPanel) }

    /// The menu switch, on: into the panel, unfolded, its effect on. One history step.
    public func addToPanel(_ e: ProEntry) {
        proOpen.insert(e.id)
        grouped("Add \(e.name)", target: "pro.add.\(history.count)") {
            for m in e.modules { setInPanel(m, true) }
        }
        Task { for m in e.modules { await loadSchema(for: m) } }
    }

    /// The menu switch, off: out of the panel, edits cleared and switched off, so it no longer applies.
    /// One history step; undo puts it back as it was.
    public func removeFromPanel(_ e: ProEntry) {
        grouped("Remove \(e.name)", target: "pro.remove.\(history.count)") {
            for m in e.modules { setInPanel(m, false) }
        }
        proOpen.remove(e.id)
    }

    public func toggleInPanel(_ e: ProEntry) { inProPanel(e) ? removeFromPanel(e) : addToPanel(e) }

    /// The power button: the effect off or on; the section stays.
    public func proEffectOn(_ e: ProEntry) -> Bool { e.modules.contains(where: isEnabled) }
    public func toggleProEffect(_ e: ProEntry) {
        let on = !proEffectOn(e)
        grouped(on ? "\(e.name) on" : "\(e.name) off", target: "pro.power.\(history.count)") {
            for m in e.modules where !m.hideEnableButton { setEnabled(m, on) }
        }
    }

    public func proEdited(_ e: ProEntry) -> Bool { e.modules.contains(where: isEdited) }
    public func resetProEntry(_ e: ProEntry) {
        grouped("Reset \(e.name)", target: "pro.reset.\(history.count)") { e.modules.forEach(resetModule) }
    }

    public func toggleProFold(_ e: ProEntry) { if proOpen.contains(e.id) { proOpen.remove(e.id) } else { proOpen.insert(e.id) } }

    /// Schemas for everything in the panel, so each section's controls can show.
    public func preparePro() async {
        for e in proPanelEntries { for m in e.modules { await loadSchema(for: m) } }
    }

    // MARK: the tone curve's points (the clean engine's tonecurve fields n, x0...x7, y0...y7)

    public static let curveMaxPoints = ToneCurve.maxPoints
    public static let curveMinGap = ToneCurve.minGap

    public struct CurvePoint: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// The curve's points, safe to draw and evaluate: the point curve when `n` is 2 or more, else the five heights an earlier
    /// version saved (at x = 0, 0.25, 0.5, 0.75, 1). Nil when this tone curve has no such fields (the darktable engine's).
    public var curvePoints: [CurvePoint]? {
        guard let m = proModule("tonecurve"), let fields = schemas["tonecurve"]?.fields else { return nil }
        func v(_ name: String) -> Double? { fields.first { $0.name == name }.flatMap { value(m, $0).double } }
        guard v("y0") != nil else { return nil }
        let n = (v("n") ?? 0).clampedInt
        let xs: [Double], ys: [Double]
        if n >= 2 {
            let count = min(n, ToneCurve.maxPoints)
            xs = (0..<count).map { v("x\($0)") ?? 1 }
            ys = (0..<count).map { v("y\($0)") ?? 1 }
        } else {
            xs = ToneCurve.legacyXs
            ys = (0..<5).map { v("y\($0)") ?? Double($0) / 4 }
        }
        let s = ToneCurve.sanitized(xs: xs, ys: ys)
        return zip(s.xs, s.ys).map { CurvePoint(x: $0, y: $1) }
    }

    /// The heights of the curve's points, left to right (five for an untouched curve).
    public var curveNodes: [Double]? { curvePoints?.map(\.y) }

    /// Called when a drag on the curve starts, so the moves of one drag are one history step and the next drag is another.
    public func beginCurveDrag() { curveDragSerial += 1 }

    /// Writes `points` (made safe) into the curve's fields as one history step; `target` merges repeated writes of one drag.
    private func writeCurve(_ points: [CurvePoint], label: String, target: String) {
        guard let m = proModule("tonecurve"), let fields = schemas["tonecurve"]?.fields else { return }
        let s = ToneCurve.sanitized(xs: points.map(\.x), ys: points.map(\.y))
        // every slot is written: used ones get their value, unused ones their default (which removes the key from the edit)
        var writes: [(FieldSchema, Double)] = []
        func queue(_ name: String, _ value: Double?) {
            guard let f = fields.first(where: { $0.name == name }) else { return }
            writes.append((f, value ?? f.defaultValue.double ?? 0))
        }
        queue("n", Double(s.xs.count))
        for i in 0..<ToneCurve.maxPoints {
            queue("x\(i)", i < s.xs.count ? s.xs[i] : nil)
            queue("y\(i)", i < s.ys.count ? s.ys[i] : nil)
        }
        grouped(label, target: target) {
            for (f, v) in writes { setParam(m, f, to: .number(v)) }
        }
    }

    /// Moves point `index` to (x, y), both 0...1. A point stays between its neighbours (at least `ToneCurve.minGap` apart in x,
    /// never lower than the one before or higher than the one after), so the curve never folds back or reverses a tone. The end
    /// points can move too: the first right of 0 is a black point, the last left of 1 a white point.
    public func moveCurvePoint(_ index: Int, x: Double, y: Double) {
        guard var pts = curvePoints, pts.indices.contains(index), x.isFinite, y.isFinite else { return }
        let gap = ToneCurve.minGap, last = pts.count - 1
        let xLo = index == 0 ? 0 : pts[index - 1].x + gap, xHi = index == last ? 1 : pts[index + 1].x - gap
        let yLo = index == 0 ? 0 : pts[index - 1].y, yHi = index == last ? 1 : pts[index + 1].y
        pts[index].x = min(max(x, xLo), max(xLo, xHi))
        pts[index].y = min(max(y, yLo), max(yLo, yHi))
        guard pts != curvePoints else { return }
        writeCurve(pts, label: "Tone curve", target: "tonecurve.drag.\(curveDragSerial)")
    }

    /// Adds a point at (x, y) (clamped between its new neighbours). Returns its index, or nil when the curve has eight already or
    /// the spot is closer than `ToneCurve.minGap` to another point.
    @discardableResult
    public func insertCurvePoint(x: Double, y: Double) -> Int? {
        guard var pts = curvePoints, pts.count < ToneCurve.maxPoints, x.isFinite, y.isFinite else { return nil }
        let gap = ToneCurve.minGap
        guard let j = pts.firstIndex(where: { $0.x > x }), j > 0 else { return nil }
        guard x - pts[j - 1].x >= gap, pts[j].x - x >= gap else { return nil }
        pts.insert(CurvePoint(x: x, y: min(max(y, pts[j - 1].y), pts[j].y)), at: j)
        writeCurve(pts, label: "Add curve point", target: "tonecurve.add.\(history.count)")
        return j
    }

    /// Takes point `index` out. The two end points stay, and so do two points in all.
    public func removeCurvePoint(_ index: Int) {
        guard var pts = curvePoints, pts.count > 2, (1..<(pts.count - 1)).contains(index) else { return }
        pts.remove(at: index)
        writeCurve(pts, label: "Remove curve point", target: "tonecurve.remove.\(history.count)")
    }

    /// Moves point `index` to height `y` keeping its place along the curve (the rig and the self-test use this).
    public func setCurveNode(_ index: Int, _ y: Double) {
        guard let pts = curvePoints, pts.indices.contains(index) else { return }
        moveCurvePoint(index, x: pts[index].x, y: y)
    }
}

// MARK: views

/// Pro's right column: the scopes, then one foldable section per module in the panel.
struct ProPanel: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        VStack(spacing: 12) {
            // a compact scope: the sections are what Pro is for, and the curve must be on screen at 860 pt
            ScopesCard(model: model)
                .frame(height: 204)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let entries = model.proPanelEntries
                    HStack(spacing: 8) {
                        Text("In the panel \u{00B7} \(entries.count)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Picker("Order", selection: Binding(get: { model.proPanelOrder }, set: { model.setProPanelOrder($0) })) {
                            ForEach(ProPanelOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 132)
                        .help("Newest: the section switched on last at the top. Pipeline: the order the engine applies them.")
                        .rig("pro-order")
                    }
                    .padding(.horizontal, 4)
                    HStack(spacing: 6) {
                        Button("All on") { model.setAllProEffects(true) }
                            .buttonStyle(.glass).controlSize(.small)
                            .disabled(!model.canSetAllProEffects(true))
                            .help("Switch every section's effect on (\u{2325}\u{2318}A)")
                            .rig("pro-all-on")
                        Button("All off") { model.setAllProEffects(false) }
                            .buttonStyle(.glass).controlSize(.small)
                            .disabled(!model.canSetAllProEffects(false))
                            .help("Switch every section's effect off; the sections and their settings stay (\u{2325}\u{2318}0)")
                            .rig("pro-all-off")
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    ForEach(entries) { e in ProSection(model: model, entry: e) }
                    if entries.isEmpty {
                        Text("The panel is empty. Open Modules in the header and switch one on.")
                            .font(.callout).foregroundStyle(.secondary).padding(8)
                    }
                }
                .padding(12)
            }
            .rig("pro-panel")
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
        .task(id: model.proPanelEntries.map(\.id).joined(separator: ",")) { await model.preparePro() }
    }
}

struct ProSection: View {
    @Bindable var model: DarkroomModel
    let entry: DarkroomModel.ProEntry

    var body: some View {
        let on = model.proEffectOn(entry), open = model.proOpen.contains(entry.id)
        // dimmed only when an edit is switched off: a basic at neutral is off in the engine but changes nothing
        let dim = !on && model.proEdited(entry)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { model.toggleProEffect(entry) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(on ? Theme.accent : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(entry.modules.allSatisfy(\.hideEnableButton))
                .accessibilityLabel(on ? "Turn \(entry.name) off" : "Turn \(entry.name) on")
                .rig("pro-power-\(entry.rigName)")

                Button { model.toggleProFold(entry) } label: {
                    HStack {
                        Text(entry.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 0 : -90))
                    }
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Fold \(entry.name)" : "Unfold \(entry.name)")
                .rig("pro-fold-\(entry.rigName)")

                if open && model.proEdited(entry) {
                    Button("Reset") { model.resetProEntry(entry) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .rig("pro-reset-\(entry.rigName)")
                }
            }
            if open {
                body(for: entry)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                    .opacity(dim ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .opacity(dim ? 0.75 : 1)
    }

    @ViewBuilder
    private func body(for e: DarkroomModel.ProEntry) -> some View {
        let op = e.modules[0].operation
        if op == "tonecurve", e.modules[0].multiPriority == 0, model.curveNodes != nil {
            CurveSection(model: model, module: e.modules[0])
        } else {
            ForEach(e.modules) { m in ParamList(model: model, module: m) }
            if op == "temperature" { AutoWhiteBalanceButton(model: model, id: "pro-awb") }
        }
        // limit the module to part of the picture; only a module the engine can blend (not geometry, not the display transform)
        if e.modules.count == 1, let m = e.modules.first, m.supportsBlending, m.blend != nil {
            BlendSection(model: model, module: m)
        }
    }
}

/// The tone curve section: the curve editor (CurveEditor, its own file) above the five node values.
struct CurveSection: View {
    @Bindable var model: DarkroomModel
    let module: ModuleInfo

    var body: some View {
        CurveEditor(model: model)
            .frame(height: 244)
    }
}

/// The header's three Pro menus: Modules (in or out of the panel), Presets, History.
struct ProMenus: View {
    @Bindable var model: DarkroomModel
    /// The narrow header: icons with tooltips instead of words.
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            Button { model.setLibraryShown(!model.libraryShown) } label: { menuLabel("Library", "books.vertical", chevron: false) }
                .buttonStyle(.plain)
                .background(model.libraryShown ? Color.white.opacity(0.14) : .clear, in: Capsule())
                .accessibilityAddTraits(model.libraryShown ? .isSelected : [])
                .help("Show or hide the library (\u{2318}\u{21E7}L)")
                .rig("pro-library")
            menuButton(.modules, "Modules", "slider.horizontal.3").rig("pro-modules")
            menuButton(.presets, "Presets", "square.stack").rig("pro-presets")
            menuButton(.history, "History", "clock.arrow.circlepath").rig("pro-history")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    /// A header button that opens its dropdown (drawn by DarkroomView, under this button's frame).
    private func menuButton(_ kind: ProMenuKind, _ title: String, _ symbol: String) -> some View {
        let open = model.proMenuOpen == kind
        return Button { model.proMenuOpen = open ? nil : kind } label: { menuLabel(title, symbol) }
            .buttonStyle(.plain)
            .background(open ? Color.white.opacity(0.14) : .clear, in: Capsule())
            .anchorPreference(key: ProMenuAnchorKey.self, value: .bounds) { [kind: $0] }
            .accessibilityAddTraits(open ? .isSelected : [])
    }

    private func menuLabel(_ title: String, _ symbol: String, chevron: Bool = true) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            // words keep their size, so the header's wide layout is only chosen when they fit
            if !compact { Text(title).font(.callout.weight(.medium)).lineLimit(1).fixedSize() }
            if chevron { Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, compact ? 6 : 10)
        .frame(height: 40)
        .contentShape(Rectangle())
        .help(title)
        .accessibilityLabel(title)
    }
}
