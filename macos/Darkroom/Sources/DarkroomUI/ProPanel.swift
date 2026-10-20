import DarkroomCore
import DarktableKit
import SwiftUI

/// Pro mode's side panel holds the modules in use; the header's Modules menu puts them in or takes them out.
/// Two kinds of off, kept apart on purpose (owner's rule): the menu switch takes a module out of the panel and
/// stops applying it; the section's power button only turns its effect off, and the section stays with its settings.
extension DarkroomModel {
    /// The ten modules most edits use, first in the Modules menu. "Crop and straighten" is crop and ashift together.
    static let proCommon: [[String]] = [
        ["temperature"], ["exposure"], ["tonecurve"], ["shadhi"], ["colorbalancergb"],
        ["splittoning"], ["monochrome"], ["sharpen"], ["denoiseprofile"], ["crop", "ashift"],
    ]
    /// A new photo starts with these in the panel, at neutral settings.
    public static let proBasics: Set<String> = ["temperature", "exposure", "tonecurve", "colorbalancergb"]

    /// The menu's groups, by operation; anything not listed (darktable has many more) goes under Other.
    static let proGroups: [(name: String, operations: Set<String>)] = [
        ("Tone", ["temperature", "exposure", "tonecurve", "rgbcurve", "rgblevels", "basecurve", "shadhi", "relight",
                  "zonesystem", "basicadj", "display", "toneequal", "filmicrgb", "sigmoid", "agx", "highlights"]),
        ("Color", ["colorbalancergb", "channelmixer", "channelmixerrgb", "velvia", "vibrance", "colorize", "colorcontrast",
                   "colorcorrection", "splittoning", "monochrome", "primaries", "satcurvergb", "colorequal", "colisa",
                   "invert", "negadoctor", "colorzones", "lut3d"]),
        ("Detail", ["sharpen", "denoiseprofile", "bilat", "clahe", "atrous", "highpass", "lowpass", "blurs", "diffuse",
                    "nlmeans", "hotpixels", "rawdenoise"]),
        ("Geometry", ["flip", "ashift", "crop", "lens", "liquify", "retouch", "spots"]),
        ("Effects", ["vignette", "bloom", "grain", "soften", "dither", "censorize", "lowlight", "graduatednd", "hazeremoval"]),
    ]

    /// The module behind an operation (the first instance).
    func proModule(_ operation: String) -> ModuleInfo? { modules.first { $0.operation == operation } }

    /// What "out of the panel" leaves a module at: no edits, switched off unless it is off by default anyway.
    private func removalEdit(_ m: ModuleInfo) -> ModuleEdit {
        var e = ModuleEdit()
        if m.enabled && !m.hideEnableButton { e.enabled = false }
        return e
    }

    /// In the panel: the basics, anything added from the menu, anything with edits, except a module taken out
    /// that is still exactly as taking it out left it (editing it again, or undo, brings it back).
    public func inProPanel(_ m: ModuleInfo) -> Bool {
        if proRemoved.contains(m.id), (edits[m.id] ?? ModuleEdit()) == removalEdit(m) { return false }
        return Self.proBasics.contains(m.operation) || proAdded.contains(m.id) || isEdited(m)
    }

    /// One panel entry per module, or per group of modules shown as one section (crop and straighten).
    public struct ProEntry: Identifiable {
        public let id: String
        public let name: String
        public let modules: [ModuleInfo]
    }

    private func entry(for operations: [String]) -> ProEntry? {
        let ms = operations.compactMap(proModule)
        guard let first = ms.first else { return nil }
        let name = operations == ["crop", "ashift"] ? "Crop and straighten" : first.title
        return ProEntry(id: first.id, name: name, modules: ms)
    }

    /// The panel's sections, in the order the engine applies them.
    public var proPanelEntries: [ProEntry] {
        var seen = Set<String>(), out: [(Int, ProEntry)] = []
        let combined = Set(["crop", "ashift"])
        for m in modules where inProPanel(m) && !seen.contains(m.id) {
            if combined.contains(m.operation) {
                guard let e = entry(for: ["crop", "ashift"]) else { continue }
                e.modules.forEach { seen.insert($0.id) }
                out.append((e.modules.map(\.iopOrder).min() ?? m.iopOrder, e))
            } else {
                seen.insert(m.id)
                out.append((m.iopOrder, ProEntry(id: m.id, name: m.title, modules: [m])))
            }
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The Modules menu: the common ten first, then everything else by kind.
    public var proMenu: [(group: String, entries: [ProEntry])] {
        let common = Self.proCommon.compactMap(entry(for:))
        let commonOps = Set(Self.proCommon.flatMap { $0 })
        var groups: [(String, [ProEntry])] = [("Common", common)]
        let rest = modules.filter { !commonOps.contains($0.operation) && !$0.deprecated }
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

    /// The menu switch, on: into the panel, unfolded, its effect on.
    public func addToPanel(_ e: ProEntry) {
        for m in e.modules {
            proRemoved.remove(m.id)
            proAdded.insert(m.id)
        }
        proOpen.insert(e.id)
        grouped("Add \(e.name)", target: "pro.add.\(history.count)") {
            for m in e.modules where !isEnabled(m) && !m.hideEnableButton { setEnabled(m, true) }
        }
        Task { for m in e.modules { await loadSchema(for: m) } }
    }

    /// The menu switch, off: out of the panel and no longer applied, as one history step that undo reverses.
    public func removeFromPanel(_ e: ProEntry) {
        grouped("Remove \(e.name)", target: "pro.remove.\(history.count)") {
            for m in e.modules {
                resetModule(m)
                if isEnabled(m) && !m.hideEnableButton { setEnabled(m, false) }
            }
        }
        for m in e.modules {
            proAdded.remove(m.id)
            proRemoved.insert(m.id)
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

    // MARK: the tone curve's five nodes (the clean engine's tonecurve fields y0...y4)

    /// The heights of the five nodes at x = 0, 0.25, 0.5, 0.75, 1, or nil when this tone curve has no such fields.
    public var curveNodes: [Double]? {
        guard let m = proModule("tonecurve") else { return nil }
        var ys: [Double] = []
        for i in 0..<5 {
            guard let f = schemas["tonecurve"]?.fields.first(where: { $0.name == "y\(i)" }), let v = value(m, f).double else { return nil }
            ys.append(v)
        }
        return ys
    }

    /// Moves node `index` to height `y` (0...1). Dragging one node is one history step (the same field merges).
    public func setCurveNode(_ index: Int, _ y: Double) {
        guard (0..<5).contains(index), let m = proModule("tonecurve"),
              let f = schemas["tonecurve"]?.fields.first(where: { $0.name == "y\(index)" }) else { return }
        setParam(m, f, to: .number(min(max(y, 0), 1)))
    }
}

// MARK: views

/// Pro's right column: the scopes, then one foldable section per module in the panel.
struct ProPanel: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        VStack(spacing: 12) {
            ScopesCard(model: model)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let entries = model.proPanelEntries
                    HStack {
                        Text("In the panel \u{00B7} \(entries.count)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { model.toggleProEffect(entry) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(on ? Theme.accent : Color.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(entry.modules.allSatisfy(\.hideEnableButton))
                .accessibilityLabel(on ? "Turn \(entry.name) off" : "Turn \(entry.name) on")
                .rig("pro-power-\(entry.modules[0].operation)")

                Button { model.toggleProFold(entry) } label: {
                    HStack {
                        Text(entry.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 0 : -90))
                    }
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Fold \(entry.name)" : "Unfold \(entry.name)")
                .rig("pro-fold-\(entry.modules[0].operation)")

                if open && model.proEdited(entry) {
                    Button("Reset") { model.resetProEntry(entry) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .rig("pro-reset-\(entry.modules[0].operation)")
                }
            }
            if open {
                body(for: entry)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                    .opacity(on ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .opacity(on ? 1 : 0.75)
    }

    @ViewBuilder
    private func body(for e: DarkroomModel.ProEntry) -> some View {
        let op = e.modules[0].operation
        if op == "tonecurve", model.curveNodes != nil {
            CurveSection(model: model, module: e.modules[0])
        } else if e.modules.map(\.operation) == ["crop", "ashift"] || Set(e.modules.map(\.operation)) == ["crop", "ashift"] {
            ProGeometry(model: model)
        } else {
            ForEach(e.modules) { m in ParamList(model: model, module: m) }
        }
    }
}

/// The tone curve section: the curve editor (CurveEditor, its own file) above the five node values.
struct CurveSection: View {
    @Bindable var model: DarkroomModel
    let module: ModuleInfo

    var body: some View {
        CurveEditor(model: model)
            .frame(height: 220)
    }
}

/// Straighten, rotate and the aspect presets, the same controls and API as Simple mode's.
struct ProGeometry: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Straighten").font(.callout)
                Spacer()
                Text(String(format: "%+.1f\u{00B0}", model.simpleStraighten)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { model.simpleStraighten }, set: { model.setStraighten($0) }),
                   in: DarkroomModel.straightenRange, step: 0.1, onEditingChanged: { model.setDragging($0) })
                .tint(Theme.accent)
                .accessibilityLabel("Straighten")
                .rig("pro-straighten")
            HStack(spacing: 6) {
                Button { model.rotate90() } label: { Label("Rotate 90\u{00B0}", systemImage: "rotate.right").frame(maxWidth: .infinity, minHeight: 32) }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .rig("pro-rotate")
            }
            HStack(spacing: 6) {
                ForEach(SimpleAspect.allCases) { a in
                    Button { model.setAspect(a) } label: {
                        Text(a.rawValue).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(Color.white.opacity(model.simpleAspect == a ? 0.26 : 0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a.spoken)
                    .accessibilityAddTraits(model.simpleAspect == a ? .isSelected : [])
                    .rig("pro-aspect-\(a.slug)")
                }
            }
        }
        .disabled(!model.simpleGeometryReady)
        .task { await model.prepareSimple() }
    }
}

/// The header's three Pro menus: Modules (in or out of the panel), Presets, History.
struct ProMenus: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(model.proMenu, id: \.group) { g in
                    Section(g.group) {
                        ForEach(g.entries) { e in
                            Toggle(e.name, isOn: Binding(get: { model.inProPanel(e) }, set: { _ in model.toggleInPanel(e) }))
                        }
                    }
                }
            } label: { menuLabel("Modules", "slider.horizontal.3") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .rig("pro-modules")

            Menu {
                ForEach(SimpleLook.all) { look in Button(look.name) { model.apply(look) } }
            } label: { menuLabel("Presets", "square.stack") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .rig("pro-presets")

            Menu {
                ForEach(Array(model.history.enumerated()).reversed(), id: \.offset) { i, item in
                    Button { model.jump(to: i) } label: {
                        if i == model.historyIndex { Label(item.label, systemImage: "checkmark") } else { Text(item.label) }
                    }
                }
            } label: { menuLabel("History", "clock.arrow.circlepath") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .rig("pro-history")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private func menuLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title).font(.callout.weight(.medium))
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .contentShape(Rectangle())
    }
}
