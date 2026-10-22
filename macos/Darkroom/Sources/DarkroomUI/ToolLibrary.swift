import DarkroomCI
import DarkroomEngineAPI
import DarktableKit
import SwiftUI

/// The library, Pro's left panel (owner's rule of 2026-10-22, after Logic Pro's Sounds library): a search above, categories down
/// the left, the category's items on the right, and what was picked last at the top. It lists the modules by kind, the looks, the
/// presets (the modules folded into another, by their old names) and the masks. A module row's switch puts it in the right panel;
/// a look or a preset applies; a mask goes on the section that is open in the right panel.
public enum LibraryCategory: String, CaseIterable, Identifiable, Sendable {
    case common, tone, color, detail, geometry, effects, other, looks, presets, masks

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .common: "Common"
        case .tone: "Tone"
        case .color: "Color"
        case .detail: "Detail"
        case .geometry: "Geometry"
        case .effects: "Effects"
        case .other: "Other"
        case .looks: "Looks"
        case .presets: "Presets"
        case .masks: "Masks"
        }
    }
    var symbol: String {
        switch self {
        case .common: "star"
        case .tone: "sun.max"
        case .color: "paintpalette"
        case .detail: "sparkles"
        case .geometry: "crop.rotate"
        case .effects: "wand.and.stars"
        case .other: "ellipsis.circle"
        case .looks: "camera.filters"
        case .presets: "square.stack.3d.up"
        case .masks: "person.crop.circle.dashed"
        }
    }
    /// The Modules menu group this category lists, or nil for looks, presets and masks.
    public var menuGroup: String? {
        switch self {
        case .looks, .presets, .masks: nil
        default: title
        }
    }
}

/// One row of the library.
public struct LibraryEntry: Identifiable {
    public enum Kind {
        case module(DarkroomModel.ProEntry)
        case look(SimpleLook)
        case preset(DarkroomModel.LibraryPreset)
        case mask(MaskLayerKind)
    }
    public let id: String
    public let name: String
    /// A second line: what a preset sets up, what a mask does.
    public let detail: String
    public let kind: Kind
    /// Words a search can hit besides the name.
    let keywords: String
}

extension DarkroomModel {
    /// A module folded into another (`CIEngineProbe.aliases`), offered by its old name: picking it puts the survivor in the panel
    /// with that method chosen and the old module's starting values.
    public struct LibraryPreset: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let survivor: String
    }

    /// The folded modules as presets, by name; only those whose survivor this engine has.
    public var libraryPresets: [LibraryPreset] {
        CIEngineProbe.aliases
            .map { LibraryPreset(id: $0.key, name: $0.value.name, survivor: $0.value.survivor) }
            .filter { proModule($0.survivor) != nil }
            .sorted { $0.name < $1.name }
    }

    /// The categories this engine can fill: masks need the clean engine's local masks.
    public var libraryCategories: [LibraryCategory] {
        LibraryCategory.allCases.filter { c in
            switch c {
            case .masks: localMasks
            case .presets: !libraryPresets.isEmpty
            case .other: proMenu.contains { $0.group == "Other" }
            default: true
            }
        }
    }

    /// The rows of one category.
    public func libraryEntries(_ c: LibraryCategory) -> [LibraryEntry] {
        switch c {
        case .looks:
            return SimpleLook.all.map { LibraryEntry(id: "look-\($0.id)", name: $0.name, detail: "look", kind: .look($0), keywords: "look filter preset") }
        case .presets:
            return libraryPresets.map {
                LibraryEntry(id: "preset-\($0.id)", name: $0.name, detail: "sets up \(proModule($0.survivor)?.title ?? $0.survivor)",
                             kind: .preset($0), keywords: "\($0.id) \($0.survivor) preset")
            }
        case .masks:
            return MaskLayerKind.allCases.map { k in
                let name = k == .brush ? "brush" : "find the \(k.title)"
                let detail = k == .brush ? "paint where the edit applies" : "Vision finds it; the edit applies there"
                return LibraryEntry(id: "mask-\(k.rawValue)", name: name, detail: detail, kind: .mask(k), keywords: "mask \(k.rawValue) detect face object")
            }
        default:
            guard let g = c.menuGroup, let entries = proMenu.first(where: { $0.group == g })?.entries else { return [] }
            return entries.map { LibraryEntry(id: "module-\($0.id)", name: $0.name, detail: "", kind: .module($0), keywords: $0.modules.map(\.operation).joined(separator: " ")) }
        }
    }

    /// Every category's rows that the query hits, by category; empty query, nothing.
    public func librarySearch(_ query: String) -> [(category: LibraryCategory, entries: [LibraryEntry])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        return libraryCategories.compactMap { c in
            let hits = libraryEntries(c).filter { e in
                guard !seen.contains(e.id) else { return false }
                return e.name.lowercased().contains(q) || e.detail.lowercased().contains(q) || e.keywords.lowercased().contains(q)
            }
            hits.forEach { seen.insert($0.id) }
            return hits.isEmpty ? nil : (c, hits)
        }
    }

    /// A preset: the survivor into the panel and on, its method and the old module's starting values set, the section unfolded.
    /// One history step.
    public func applyLibraryPreset(_ p: LibraryPreset) async {
        guard let m = proModule(p.survivor), let a = CIEngineProbe.aliases[p.id] else { return }
        await loadSchema(for: m)
        guard let fields = schema(for: m)?.fields else { return }
        let values = a.map([:])
        grouped("\(p.name) preset", target: "library.preset.\(history.count)") {
            if !inProPanel(m) { setInPanel(m, true) }
            if !m.hideEnableButton && !isEnabled(m) { setEnabled(m, true) }
            for f in fields { if let v = values[f.name] { setParam(m, f, to: v) } }
        }
        proOpen.insert(m.id)
        libraryPicked = "preset-\(p.id)"
    }

    /// The section a mask from the library goes on: the unfolded section highest in the panel that can be blended, else the
    /// highest one that can.
    public var libraryMaskTarget: ModuleInfo? {
        let able = proPanelEntries.filter { $0.modules.count == 1 }.map { $0.modules[0] }.filter { $0.supportsBlending && $0.blend != nil }
        return able.first { proOpen.contains($0.id) } ?? able.first
    }

    /// A mask on the target section: the brush starts painting, a Vision kind runs the finder; the section and its Blend open.
    public func applyLibraryMask(_ k: MaskLayerKind) async {
        guard let m = libraryMaskTarget else { return }
        proOpen.insert(m.id)
        blendOpen = true
        libraryPicked = "mask-\(k.rawValue)"
        if k == .brush { startBrush(m) } else if let v = k.vision { await detect(v, for: m) }
    }

    /// A merged module's method switch, and the controls that belong to one method only. A control not listed shows whatever the
    /// method; one listed shows for the methods that name it. The catalogue (CIModules.swift) is the source: each entry's `apply`
    /// reads these fields under that method and no others.
    static let methodFields: [String: (switch: String, only: [String: Set<String>])] = [
        "sharpen": ("method", ["deconvolution": ["iterations"]]),
        "denoiseprofile": ("method", ["wavelet": ["luma", "chroma"], "nonlocal": ["amount", "strength"], "colour": ["radius", "amount"]]),
        "monochrome": ("method", ["filter": ["filter_hue", "filter_strength"], "weights": ["red", "green", "blue"]]),
        "bloom": ("glow", ["film": ["hue"]]),
        "blurs": ("mode", ["soft": ["strength"]]),
        "warmth": ("method", ["offset": ["warmth", "tint"], "filter": ["hue", "density", "preserve"]]),
        "highlightrolloff": ("curve", ["shoulder": ["knee"]]),
        "surfaceblur": ("method", ["guided": ["amount", "radius", "threshold"], "bilateral": ["amount", "radius", "range"],
                                   "anisotropic": ["iterations", "edge"], "skin": ["amount", "radius", "hue", "width"]]),
    ]

    /// The fields of `m` its current method uses, in schema order.
    public func shownFields(_ m: ModuleInfo, _ fields: [FieldSchema]) -> [FieldSchema] {
        guard let t = Self.methodFields[m.operation], let sw = fields.first(where: { $0.name == t.switch }) else { return fields }
        let current = value(m, sw).option ?? sw.defaultValue.option ?? ""
        let mine = t.only[current] ?? []
        let claimed = Set(t.only.values.flatMap { $0 })
        return fields.filter { !claimed.contains($0.name) || mine.contains($0.name) }
    }
}

// MARK: views

struct ToolLibrary: View {
    @Bindable var model: DarkroomModel
    @FocusState private var searching: Bool

    static let width: CGFloat = 332
    private static let categoryWidth: CGFloat = 110

    private var query: String { model.libraryQuery }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TextField("Search the library", text: $model.libraryQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
                .focused($searching)
                .accessibilityLabel("Search the library")
                .rig("lib-search")
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    categories.frame(width: Self.categoryWidth)
                    Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1)
                    items(model.libraryEntries(model.libraryCategory), category: model.libraryCategory)
                }
            } else {
                results
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .rig("library")
        .onChange(of: model.libraryFindSerial) { _, _ in searching = true }
        .onAppear { if !model.libraryCategories.contains(model.libraryCategory) { model.libraryCategory = .common } }
    }

    /// What was picked last (a look, a preset, a mask, a module), with the category's symbol, like the patch art at the top of
    /// Logic's library; the category itself when nothing was picked yet.
    @ViewBuilder private var header: some View {
        let hit: (LibraryCategory, LibraryEntry)? = model.libraryPicked.flatMap { id in
            model.libraryCategories.lazy.compactMap { c in model.libraryEntries(c).first { $0.id == id }.map { (c, $0) } }.first
        }
        let picked = hit?.1, category = hit?.0 ?? model.libraryCategory
        HStack(spacing: 10) {
            Image(systemName: category.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text(picked?.name ?? "Library").font(.callout.weight(.semibold)).lineLimit(1)
                Text(picked.map { $0.detail.isEmpty ? category.title : $0.detail } ?? "modules, looks, presets and masks")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.setLibraryShown(false) } label: {
                Image(systemName: "sidebar.leading").font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide the library (\u{2318}\u{21E7}L)")
            .accessibilityLabel("Hide the library")
            .rig("lib-close")
        }
        .rig("lib-header")
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.libraryCategories) { c in
                let selected = model.libraryCategory == c
                DropdownRow(selected: selected) { model.libraryCategory = c } content: {
                    HStack(spacing: 8) {
                        Image(systemName: c.symbol).font(.system(size: 12)).foregroundStyle(selected ? Theme.accent : .secondary).frame(width: 16)
                        Text(c.title).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .accessibilityLabel(c.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .rig("lib-cat-\(c.id)")
            }
        }
    }

    private func items(_ entries: [LibraryEntry], category: LibraryCategory) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { e in row(e) }
                if entries.isEmpty {
                    Text("Nothing here on this engine.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(8)
                }
                if category == .masks { maskTargetNote }
            }
        }
        .frame(maxHeight: 520)
        .scrollIndicators(.hidden)
    }

    /// Every category's hits for the query, each under its heading.
    private var results: some View {
        let groups = model.librarySearch(query)
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups, id: \.category) { g in
                    Text(g.category.title.uppercased())
                        .font(.system(size: 10.5, design: .monospaced)).tracking(0.9).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(g.entries) { e in row(e) }
                }
                if groups.isEmpty {
                    Text("Nothing named \"\(query)\"").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(8)
                }
            }
        }
        .frame(maxHeight: 520)
        .scrollIndicators(.hidden)
        .rig("lib-results")
    }

    @ViewBuilder private func row(_ e: LibraryEntry) -> some View {
        switch e.kind {
        case .module(let entry):
            DropdownModuleRow(model: model, entry: entry, rigPrefix: "lib")
                .simultaneousGesture(TapGesture().onEnded { model.libraryPicked = e.id })
        case .look(let look):
            DropdownRow { model.apply(look); model.libraryPicked = e.id } content: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: look.swatch, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 30, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                    Text(look.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .accessibilityLabel("\(look.name) look")
            .rig("lib-look-\(look.id)")
        case .preset(let p):
            DropdownRow { Task { await model.applyLibraryPreset(p) } } content: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.name).font(.system(size: 13)).lineLimit(1)
                    Text(e.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityLabel("\(p.name) preset")
            .rig("lib-preset-\(p.id)")
        case .mask(let k):
            DropdownRow { Task { await model.applyLibraryMask(k) } } content: {
                HStack(spacing: 10) {
                    Image(systemName: k == .brush ? "paintbrush.pointed" : "viewfinder").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(e.name).font(.system(size: 13)).lineLimit(1)
                        Text(e.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .disabled(model.libraryMaskTarget == nil || model.maskBusy != nil)
            .accessibilityLabel(k == .brush ? "Paint a mask with the brush" : "Find the \(k.title) in the photo")
            .rig("lib-mask-\(k.rawValue)")
        }
    }

    /// Under the masks: which section the mask goes on, or what to do first.
    @ViewBuilder private var maskTargetNote: some View {
        if let busy = model.maskBusy {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(busy).font(.caption).foregroundStyle(.secondary) }.padding(8)
        } else if let t = model.libraryMaskTarget {
            Text("Goes on \(t.title), the open section in the panel.").font(.caption).foregroundStyle(.secondary).padding(8).rig("lib-mask-target")
        } else {
            Text("Switch a module on first; the mask goes on the open section in the panel.").font(.caption).foregroundStyle(.secondary).padding(8).rig("lib-mask-target")
        }
    }
}
