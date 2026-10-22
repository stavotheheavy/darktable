import SwiftUI

/// Where each Pro header button sits, so its dropdown can open right under it (design canvas, layout B).
struct ProMenuAnchorKey: PreferenceKey {
    static let defaultValue: [ProMenuKind: Anchor<CGRect>] = [:]
    static func reduce(value: inout [ProMenuKind: Anchor<CGRect>], nextValue: () -> [ProMenuKind: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The dropdown under a Pro header button: Modules (a search field, the common ten first, then each group, a switch per
/// module), Presets (the looks as tiles) or History (the steps, newest first). One look for all three, as the board draws it.
struct ProDropdown: View {
    @Bindable var model: DarkroomModel
    let kind: ProMenuKind
    private var query: String { model.proMenuQuery }
    @FocusState private var searching: Bool
    @State private var listHeight: CGFloat = 0

    static func width(_ kind: ProMenuKind) -> CGFloat { kind == .modules ? 300 : kind == .crop ? 304 : 288 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch kind {
            case .modules: modules
            case .presets: presets
            case .history: history
            case .crop: CropTool(model: model)
            }
        }
        .padding(8)
        .frame(width: Self.width(kind), alignment: .leading)
        // the board's dropdown is a solid dark surface with a hairline, not see-through: its text must read over any photo
        .background(Color(red: 0.14, green: 0.153, blue: 0.216).opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 16)
        .onAppear { if kind == .modules { searching = true } }
    }

    // MARK: modules

    private struct ShownGroup: Identifiable {
        let id: String
        let entries: [DarkroomModel.ProEntry]
    }

    /// The groups the query leaves: a module stays when the query is in its name or its operation.
    private var shown: [ShownGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.proMenu.compactMap { g -> ShownGroup? in
            let entries = q.isEmpty ? g.entries : g.entries.filter { e in
                e.name.lowercased().contains(q) || e.modules.contains { $0.operation.lowercased().contains(q) }
            }
            return entries.isEmpty ? nil : ShownGroup(id: g.group, entries: entries)
        }
    }

    @ViewBuilder private var modules: some View {
        TextField("Find a module", text: $model.proMenuQuery)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
            .focused($searching)
            .padding(.horizontal, 2)
            .padding(.bottom, 4)
            .accessibilityLabel("Find a module")
            .rig("menu-search")
        let groups = shown
        if groups.isEmpty {
            Text("No module named \"\(query)\"")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 10)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { g in
                        heading(g.id)
                        ForEach(g.entries) { e in DropdownModuleRow(model: model, entry: e) }
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 1), 520))
            .scrollIndicators(.hidden)
        }
    }

    // MARK: presets

    @ViewBuilder private var presets: some View {
        heading("Presets")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 8) {
            ForEach(SimpleLook.all) { look in
                Button {
                    model.apply(look)
                    model.proMenuOpen = nil
                } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(LinearGradient(colors: look.swatch, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 52, height: 36)
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                        Text(look.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(look.name) look")
                .rig("menu-look-\(look.id)")
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    // MARK: history

    @ViewBuilder private var history: some View {
        heading("History")
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.history.enumerated()).reversed(), id: \.offset) { i, item in
                    DropdownRow(selected: i == model.historyIndex) { model.jump(to: i) } content: {
                        HStack(spacing: 10) {
                            Text(item.label).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 0)
                            if i == model.historyIndex { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                        }
                    }
                    .accessibilityLabel(item.label)
                    .accessibilityAddTraits(i == model.historyIndex ? .isSelected : [])
                    .rig("menu-history-\(i)")
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { listHeight = $0 }
        }
        .frame(height: min(max(listHeight, 1), 420))
        .scrollIndicators(.hidden)
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, design: .monospaced))
            .tracking(0.9)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One row of a dropdown: a flat button with a hover wash.
struct DropdownRow<Content: View>: View {
    var selected = false
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .frame(height: 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Theme.selectedFill : (hovering ? Color.white.opacity(0.10) : .clear),
                            in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A module in the Modules dropdown: its switch puts it in the panel or takes it out; "effect off" tells a module that
/// is in the panel with its power button off.
struct DropdownModuleRow: View {
    @Bindable var model: DarkroomModel
    let entry: DarkroomModel.ProEntry
    /// The rig id's first word: `menu` in the Modules dropdown, `lib` in the library.
    var rigPrefix = "menu"

    var body: some View {
        let inside = model.inProPanel(entry)
        DropdownRow { model.toggleInPanel(entry) } content: {
            HStack(spacing: 10) {
                PillSwitch(on: inside)
                Text(entry.name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                if inside && !model.proEffectOn(entry) && model.proEdited(entry) {
                    Text("effect off").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.name)
        .accessibilityValue(inside ? "in the panel" : "not in the panel")
        .accessibilityAddTraits(.isButton)
        .rig("\(rigPrefix)-module-\(entry.id)")
    }
}

/// The 30 by 18 pill of the board: accent when on, the knob slides.
struct PillSwitch: View {
    let on: Bool
    var body: some View {
        Capsule()
            .fill(on ? Theme.accent : Color.white.opacity(0.18))
            .frame(width: 30, height: 18)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(on ? Theme.ink : Color.white.opacity(0.55)).frame(width: 14, height: 14).padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: on)
    }
}
