import DarkroomCore
import AppKit
import DarktableKit
import SwiftUI

// MARK: left: modules and history

struct LeftPanel: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $model.leftTab) {
                ForEach(LeftTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .rig("left-tab")

            switch model.leftTab {
            case .modules: ModuleList(model: model)
            case .history: HistoryList(model: model)
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

struct ModuleList: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        let rows = model.moduleRows
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a module", text: $model.moduleQuery)
                    .textFieldStyle(.plain)
                    .rig("module-search")
                Menu {
                    Toggle("Active modules only", isOn: $model.activeOnly)
                } label: {
                    Image(systemName: model.activeOnly ? "line.3.horizontal.decrease.circle.fill"
                                                       : "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .accessibilityLabel("Filter modules")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.black.opacity(0.28), in: Capsule())

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    ForEach(Stage.allCases, id: \.self) { stage in
                        let group = rows.filter { $0.stage == stage }
                        if !group.isEmpty {
                            Text(stage.rawValue.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            ForEach(group) { row in ModuleRowView(model: model, row: row) }
                        }
                    }
                    if rows.isEmpty {
                        Text(model.modules.isEmpty ? "Open an image to see its modules."
                                                   : "No module matches “\(model.moduleQuery)”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
            .rig("module-list")
        }
    }
}

struct ModuleRowView: View {
    @Bindable var model: DarkroomModel
    let row: ModuleRow

    var body: some View {
        let selected = model.selectedID == row.id
        HStack(spacing: 0) {
            Button { model.toggleEnabled(row.module) } label: {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(row.enabled ? Theme.accent : Color.secondary.opacity(0.7))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(row.module.hideEnableButton)
            .accessibilityLabel("Enable \(row.title)")
            .accessibilityValue(row.enabled ? "on" : "off")
            .rig("enable-\(row.id)")

            Button { model.select(row.module) } label: {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.callout)
                        .foregroundStyle(row.enabled ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    if row.edited {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.title)
            .rig("module-\(row.id)")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .background(
            selected ? Theme.accent.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1))
    }
}

struct HistoryList: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(model.history.count) steps · step \(model.historyIndex) is current")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .rig("history-count")
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.history.enumerated()), id: \.element.id) { i, item in
                        let current = i == model.historyIndex
                        let future = i > model.historyIndex
                        Button { model.jump(to: i) } label: {
                            HStack(spacing: 10) {
                                Text("\(i)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.label).font(.callout).lineLimit(1)
                                    if !item.detail.isEmpty {
                                        Text(item.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 44)
                            .opacity(future ? 0.45 : 1)
                            .background(
                                current ? Theme.accent.opacity(0.22) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Step \(i): \(item.label)")
                        .rig("history-\(i)")
                        .accessibilityAddTraits(current ? .isSelected : [])
                    }
                }
            }
        }
    }
}

// MARK: right: scopes and inspector

struct RightColumn: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        VStack(spacing: 12) {
            ScopesCard(model: model)
                .frame(height: 190)
            InspectorCard(model: model)
        }
        .frame(maxHeight: .infinity)
    }
}

struct ScopesCard: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $model.scopeMode) {
                ForEach(ScopeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .rig("scope-mode")

            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.4))
                if let s = model.scopes {
                    switch model.scopeMode {
                    case .histogram: HistogramView(scopes: s)
                    case .waveform: BitmapScope(image: ScopeBitmap.waveform(s))
                    case .vectorscope: VectorScope(scopes: s)
                    }
                } else {
                    Text("No image").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model.scopeMode.rawValue) of the current frame")
            .rig("scope")

            if let s = model.scopes {
                // the readout is also the switch for the clipping warning: tap it (or press J) to paint those pixels on the photo
                Button { model.showClipping.toggle() } label: {
                    HStack {
                        clip("shadows", s.shadowClip, .blue)
                        Spacer()
                        clip("highlights", s.highlightClip, .red)
                    }
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 8)
                    .frame(height: 44)
                    .background(model.showClipping ? Theme.selectedFill : Color.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(model.showClipping ? Theme.selectedRing : Color.clear, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clipping warning")
                .accessibilityValue(model.showClipping ? "on" : "off")
                .help("Show clipped pixels on the photo (J)")
                .rig("clipping-toggle")
            } else if model.showClipping {
                EmptyView()
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func clip(_ name: String, _ fraction: Double, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(fraction > 0.001 ? color : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text("\(name) \(String(format: "%.1f", fraction * 100))%").foregroundStyle(.secondary)
        }
    }
}

struct HistogramView: View {
    let scopes: ScopeData

    var body: some View {
        Canvas { ctx, size in
            ctx.blendMode = .plusLighter
            let colors: [Color] = [.red, .green, .blue]
            for c in 0..<3 {
                var path = Path()
                let bins = scopes.histogram[c]
                path.move(to: CGPoint(x: 0, y: size.height))
                for i in 0..<bins.count {
                    let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                    path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(bins[i]) * 0.95)))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(colors[c].opacity(0.55)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct BitmapScope: View {
    let image: CGImage?

    var body: some View {
        Canvas { ctx, size in
            guard let image else { return }
            ctx.draw(Image(decorative: image, scale: 1).interpolation(.medium),
                     in: CGRect(origin: .zero, size: size))
            var grid = Path()
            for f in [0.25, 0.5, 0.75] {
                grid.move(to: CGPoint(x: 0, y: size.height * f))
                grid.addLine(to: CGPoint(x: size.width, y: size.height * f))
            }
            ctx.stroke(grid, with: .color(.white.opacity(0.14)), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct VectorScope: View {
    let scopes: ScopeData

    var body: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            if let img = ScopeBitmap.vectorscope(scopes) {
                ctx.draw(Image(decorative: img, scale: 1).interpolation(.medium), in: rect)
            }
            var g = Path()
            g.addEllipse(in: rect.insetBy(dx: side * 0.04, dy: side * 0.04))
            g.addEllipse(in: rect.insetBy(dx: side * 0.27, dy: side * 0.27))
            g.move(to: CGPoint(x: rect.midX, y: rect.minY)); g.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            g.move(to: CGPoint(x: rect.minX, y: rect.midY)); g.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            ctx.stroke(g, with: .color(.white.opacity(0.16)), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: inspector

struct InspectorCard: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let m = model.selectedModule {
                header(m)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ParamList(model: model, module: m)
                        if m.supportsBlending, m.blend != nil {
                            BlendSection(model: model, module: m)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .rig("inspector-scroll")
            } else {
                Text("Select a module to see its parameters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(6)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func header(_ m: ModuleInfo) -> some View {
        HStack(spacing: 6) {
            Button { model.toggleEnabled(m) } label: {
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.isEnabled(m) ? Theme.accent : Color.secondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(m.hideEnableButton)
            .accessibilityLabel("Enable \(m.name)")
            .rig("inspector-enable")

            Text(m.title)
                .font(.headline)
                .lineLimit(1)
                .rig("inspector-title")
            Spacer(minLength: 4)
            Button("Reset") { model.resetModule(m) }
                .buttonStyle(.glass)
                .disabled(!model.isEdited(m))
                .rig("inspector-reset")
        }
    }
}

struct ParamList: View {
    @Bindable var model: DarkroomModel
    let module: ModuleInfo
    @State private var showAll = false

    var body: some View {
        if let schema = model.schema(for: module) {
            let primary = schema.fields.filter { !isTechnical($0) }
            let fields = showAll ? schema.fields : Array(primary.prefix(12))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(fields) { f in
                    ParamRow(model: model, module: module, field: f)
                }
                if schema.fields.count > fields.count {
                    Button(showAll ? "Show fewer parameters"
                                   : "Show \(schema.fields.count - fields.count) more parameters") {
                        showAll.toggle()
                    }
                    .buttonStyle(.glass)
                    .rig("show-more")
                } else if showAll, primary.count > 12 {
                    Button("Show fewer parameters") { showAll = false }
                        .buttonStyle(.glass)
                        .rig("show-more")
                }
                if schema.fields.isEmpty {
                    note("This module has no scalar parameters. Its controls (curves, nodes, matrices) are not editable here yet.")
                }
            }
        } else if !module.haveIntrospection {
            note("This module does not describe its parameters, so it can only be switched on and off here.")
        } else {
            ProgressView().padding(8)
        }
    }

    /// Fields darktable stores for its own bookkeeping rather than for the user.
    private func isTechnical(_ f: FieldSchema) -> Bool {
        let n = f.name.lowercased()
        return n.hasPrefix("reserved") || n.hasSuffix("_version") || n == "version" || n == "unused"
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 6)
    }
}

struct ParamRow: View {
    @Bindable var model: DarkroomModel
    let module: ModuleInfo
    let field: FieldSchema

    var body: some View {
        let changed = model.isChanged(module, field)
        let id = "param-\(module.id)-\(field.name)"
        VStack(alignment: .leading, spacing: 0) {
            switch field.kind {
            case .float, .int: numeric(changed: changed, id: id)
            case .bool: toggle(changed: changed, id: id)
            case .enumeration: enumeration(changed: changed, id: id)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: numbers

    @ViewBuilder
    private func numeric(changed: Bool, id: String) -> some View {
        let current = model.value(module, field).double ?? 0
        let soft = SoftRange.range(operation: module.operation, field: field)
        HStack(spacing: 6) {
            Text(field.label)
                .font(.footnote)
                .foregroundStyle(changed ? Theme.accent : Color.secondary)
                .lineLimit(1)
                .onTapGesture(count: 2) { model.resetParam(module, field) }
                .help("Double-click to reset")
            Spacer(minLength: 4)
            NumberField(value: current, kind: field.kind, id: id) { model.setParam(module, field, to: .number($0)) }
        }
        if let soft {
            let lo = min(soft.lowerBound, current), hi = max(soft.upperBound, current)
            let curved = SoftRange.hasCurve(operation: module.operation, field: field)
            // the curve works over the soft range, widened to the current value so a typed +-8 EV still sits at the end of the track
            let limit = max(abs(lo), abs(hi))
            let binding = curved
                ? Binding(get: { ExposureCurve.position(value: current, limit: limit) },
                          set: { model.setParam(module, field, to: .number(ExposureCurve.value(position: $0, limit: limit))) })
                : Binding(get: { current }, set: { model.setParam(module, field, to: .number($0)) })
            let (trackLo, trackHi) = curved ? (-1.0, 1.0) : (lo, hi)
            Group {
                // a zero step traps in SwiftUI, so only integers get one
                if field.kind == .int, hi > lo {
                    Slider(value: binding, in: trackLo...trackHi, step: 1, onEditingChanged: { model.setDragging($0) })
                } else if hi > lo {
                    Slider(value: binding, in: trackLo...trackHi, onEditingChanged: { model.setDragging($0) })
                }
            }
            .tint(Theme.accent)
            .accessibilityLabel(field.label)
            .rig(id)
            .onAppear {
                // the rig sets a slider through the same model call its binding makes
                if Rig.enabled {
                    Rig.setters[id] = { frac in
                        let c = model.value(module, field).double ?? 0
                        let l = min(soft.lowerBound, c), h = max(soft.upperBound, c)
                        if SoftRange.hasCurve(operation: module.operation, field: field) {
                            model.setParam(module, field, to: .number(ExposureCurve.value(position: frac * 2 - 1, limit: max(abs(l), abs(h)))))
                        } else {
                            model.setParam(module, field, to: .number(l + (h - l) * frac))
                        }
                    }
                }
            }
            .onDisappear { Rig.setters[id] = nil }
        }
    }

    // MARK: toggle and enum

    private func toggle(changed: Bool, id: String) -> some View {
        Toggle(isOn: Binding(
            get: { model.value(module, field).bool ?? false },
            set: { model.setParam(module, field, to: .bool($0)) })
        ) {
            Text(field.label)
                .font(.footnote)
                .foregroundStyle(changed ? Theme.accent : Color.primary)
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
        .frame(minHeight: 30)
        .rig(id)
    }

    private func enumeration(changed: Bool, id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.label)
                .font(.footnote)
                .foregroundStyle(changed ? Theme.accent : Color.secondary)
                .onTapGesture(count: 2) { model.resetParam(module, field) }
            let binding = Binding<String>(
                get: { model.value(module, field).option ?? field.options.first?.name ?? "" },
                set: { model.setParam(module, field, to: .option($0)) })
            if field.options.count <= 3 {
                Picker(field.label, selection: binding) {
                    ForEach(field.options, id: \.name) { Text($0.label).tag($0.name) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .rig(id)
            } else {
                Picker(field.label, selection: binding) {
                    ForEach(field.options, id: \.name) { Text($0.label).tag($0.name) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .rig(id)
            }
        }
    }
}

/// A typed number next to a slider: pros want exact values.
struct NumberField: View {
    let value: Double
    let kind: FieldSchema.Kind
    let id: String
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.footnote.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 74)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .focused($focused)
            .onAppear { text = format(value) }
            .onChange(of: value) { _, new in if !focused { text = format(new) } }
            .onSubmit { apply() }
            .onChange(of: focused) { _, f in if !f { apply() } }
            .accessibilityLabel("Value")
            .rig(id + "-value")
    }

    private func apply() {
        if let d = Double(text.replacingOccurrences(of: ",", with: ".")) { commit(d) }
        text = format(value)
    }

    private func format(_ v: Double) -> String {
        kind == .int ? String(Int(v.rounded())) : String(format: abs(v) >= 100 ? "%.1f" : "%.3f", v)
    }
}

// MARK: blend

struct BlendSection: View {
    @Bindable var model: DarkroomModel
    let module: ModuleInfo
    private var open: Bool { model.blendOpen }

    static let modes: [(String, Int)] = [
        ("normal", 0x18), ("multiply", 0x04), ("screen", 0x09), ("overlay", 0x0A), ("soft light", 0x0B),
        ("hard light", 0x0C), ("lighten", 0x02), ("darken", 0x03), ("color", 0x13), ("hue", 0x12),
        ("lightness", 0x10), ("chromaticity", 0x11), ("difference", 0x17), ("add", 0x06), ("subtract", 0x07),
    ]

    private var maskMode: Int { (model.blendValue(module, "mask_mode")?.double ?? 0).clampedInt }
    private var kind: MaskKind? { MaskKind(rawValue: (model.blendValue(module, "mask_kind")?.double ?? 0).clampedInt) }
    private var opacity: Double { model.blendValue(module, "opacity")?.double ?? 100 }

    private var isRaster: Bool { (model.blendValue(module, "mask_kind")?.double ?? 0).clampedInt == 5 }
    private var layer: MaskLayer? { isRaster ? model.maskLayer(for: module) : nil }

    private var summary: String {
        switch maskMode {
        case 0: return "off"
        case 2 where model.localMasks: return "\(isRaster ? (layer?.name ?? "missing") : (kind?.title ?? "mask")) · \(opacity.clampedInt)%"
        default: return "uniform · \(opacity.clampedInt)%"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 4)
            Button { withAnimation(.smooth(duration: 0.2)) { model.blendOpen.toggle() } } label: {
                HStack {
                    Text("Blend and mask").font(.callout.weight(.semibold))
                    Spacer()
                    Text(summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption)
                }
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rig("blend-toggle")

            if open {
                if model.localMasks { localMaskControls } else { uniformControls }
            }
        }
    }

    // MARK: the clean engine: where the edit applies

    @ViewBuilder private var localMaskControls: some View {
        Text("Apply this edit")
            .font(.caption).foregroundStyle(.secondary)
        let choices: [(title: String, mode: Int, kind: MaskKind?)] =
            [("everywhere", 0, nil), ("uniform", 1, nil)] + MaskKind.allCases.map { ($0.title, 2, $0) }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(choices, id: \.title) { c in
                let selected = maskMode == c.mode && (c.mode != 2 || kind == c.kind)
                Button { model.setMask(module, mode: c.mode, kind: c.kind) } label: {
                    Text(c.title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(selected ? Theme.selectedFill : Color.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? Theme.selectedRing : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Apply \(c.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .rig("mask-kind-\(c.title)")
            }
        }
        Text("Draw or find")
            .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(MaskLayerKind.allCases, id: \.self) { k in
                let selected = maskMode == 2 && isRaster && layer?.kind == k
                Button {
                    if k == .brush { model.startBrush(module) } else if let v = k.vision { Task { await model.detect(v, for: module) } }
                } label: {
                    Text(k.title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(selected ? Theme.selectedFill : Color.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? Theme.selectedRing : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.maskBusy != nil)
                .accessibilityLabel(k == .brush ? "Paint a mask with the brush" : "Find the \(k.title) in the photo")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .rig("mask-find-\(k.title)")
            }
        }
        if let busy = model.maskBusy {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(busy).font(.caption).foregroundStyle(.secondary) }
        }
        if maskMode == 2, isRaster {
            if let layer {
                Text(layer.kind == .brush ? "\(layer.name) · \(layer.strokes.prefix(Int((model.blendValue(module, "mask_raster")?.option ?? "").split(separator: ".").last ?? "") ?? 0).count) strokes" : layer.name)
                    .font(.footnote).foregroundStyle(.secondary)
                if layer.kind == .brush { BrushControls(model: model, module: module) }
            } else {
                Text("This mask's picture is missing, so the edit does not apply.").font(.footnote).foregroundStyle(.orange)
            }
        }
        if maskMode == 2, isRaster || kind != nil {
            if let kind { ForEach(kind.controls, id: \.key) { c in MaskSlider(model: model, module: module, control: c) } }
            Toggle("Invert", isOn: Binding(
                get: { (model.blendValue(module, "mask_invert")?.double ?? 0) != 0 },
                set: { model.setBlend(module, "mask_invert", to: .number($0 ? 1 : 0), detail: "mask inverted: \($0 ? "on" : "off")") }))
                .font(.footnote)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .rig("mask-invert")
            MaskSlider(model: model, module: module, control: MaskCommon.refine)
            Toggle("Show mask", isOn: Binding(
                get: { model.maskShowID == module.id },
                set: { model.maskShowID = $0 ? module.id : nil }))
                .font(.footnote)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .rig("mask-show")
        }
        if maskMode != 0 { opacityControl }
    }

    // MARK: the darktable engine: uniform blending only

    @ViewBuilder private var uniformControls: some View {
        Picker("Mask", selection: Binding(
            get: { maskMode == 0 ? 0 : 1 },
            set: { model.setBlend(module, "mask_mode", to: .number(Double($0)),
                                  detail: "blend: \($0 == 0 ? "off" : "uniformly")") })
        ) {
            Text("off").tag(0)
            Text("uniformly").tag(1)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .rig("blend-mask")
        Text("Drawn and parametric masks are not available yet.")
            .font(.caption2)
            .foregroundStyle(.secondary)

        if maskMode != 0 {
            HStack {
                Text("Blend mode").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Picker("Blend mode", selection: Binding(
                    get: { (model.blendValue(module, "blend_mode")?.double ?? 0x18).clampedInt },
                    set: { v in
                        let name = Self.modes.first { $0.1 == v }?.0 ?? "\(v)"
                        model.setBlend(module, "blend_mode", to: .number(Double(v)), detail: "blend mode: \(name)")
                    })
                ) {
                    ForEach(Self.modes, id: \.1) { Text($0.0).tag($0.1) }
                }
                .labelsHidden()
                .frame(width: 140)
                .rig("blend-mode")
            }
            opacityControl
            Toggle("Reverse", isOn: Binding(
                get: { model.blendValue(module, "reverse")?.bool ?? false },
                set: { model.setBlend(module, "reverse", to: .bool($0), detail: "blend reversed: \($0 ? "on" : "off")") }))
                .font(.footnote)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .rig("blend-reverse")
        }
    }

    @ViewBuilder private var opacityControl: some View {
        HStack {
            Text("Opacity").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Text("\(opacity.clampedInt)%").font(.footnote.monospacedDigit())
        }
        Slider(
            value: Binding(get: { opacity }, set: {
                model.setBlend(module, "opacity", to: .number($0.rounded()), detail: "opacity: \(Int($0.rounded()))%")
            }),
            in: 0...100,
            onEditingChanged: { model.setDragging($0) }
        )
        .tint(Theme.accent)
        .accessibilityLabel("Opacity")
        .rig("blend-opacity")
    }
}

/// The brush: size, softness, flow, erase, start over. Strokes are painted on the photo itself.
struct BrushControls: View {
    @Bindable var model: DarkroomModel
    let module: ModuleInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("size", $model.brushRadius, 0.005...0.15, "brush-size") { String(format: "%.1f%%", $0 * 100) }
            row("softness", $model.brushSoftness, 0...1, "brush-softness") { String(format: "%.2f", $0) }
            row("flow", $model.brushFlow, 0.05...1, "brush-flow") { String(format: "%.2f", $0) }
            Toggle("Erase", isOn: $model.brushErase)
                .font(.footnote).toggleStyle(.switch).tint(Theme.accent).rig("brush-erase")
            HStack {
                Button("Start over") { model.clearBrush(module) }.buttonStyle(.glass).controlSize(.small).rig("brush-clear")
                Spacer()
            }
            Text(model.canPaint ? "Paint on the photo." : "Reset the crop and the zoom to paint: strokes go on the uncropped picture.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { model.paintModuleID = module.id }
        .onDisappear { if model.paintModuleID == module.id { model.paintModuleID = nil } }
    }

    private func row(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ id: String, _ text: @escaping (Double) -> String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(label).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(text(value.wrappedValue)).font(.footnote.monospacedDigit())
            }
            Slider(value: value, in: range).tint(Theme.accent).accessibilityLabel(label).rig(id)
        }
    }
}

/// One mask setting: label and value above a slider, written into the module's blend keys (one history step per drag).
struct MaskSlider: View {
    @Bindable var model: DarkroomModel
    let module: ModuleInfo
    let control: MaskControl

    var body: some View {
        let value = model.blendValue(module, control.key)?.double ?? control.defaultValue
        VStack(spacing: 2) {
            HStack {
                Text(control.label).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.\(control.decimals)f", value) + control.unit).font(.footnote.monospacedDigit())
            }
            Slider(
                value: Binding(get: { min(max(value, control.range.lowerBound), control.range.upperBound) }, set: {
                    model.setBlend(module, control.key, to: .number($0), detail: "mask \(control.label): \(String(format: "%.\(control.decimals)f", $0))\(control.unit)")
                }),
                in: control.range,
                onEditingChanged: { model.setDragging($0) }
            )
            .tint(Theme.accent)
            .accessibilityLabel(control.label)
            .rig("mask-\(control.key)")
        }
    }
}

/// The window's root: owns the engine, the library and the darkroom, and starts the engine.
public struct DarkroomRoot: View {
    @State private var model: DarkroomModel
    @State private var library: LibraryModel
    @State private var screen: Screen
    @State private var welcomed: Bool

    @MainActor public init() {
        let engine = EngineChoice.make()
        _model = State(initialValue: DarkroomModel(engine: engine))
        _library = State(initialValue: LibraryModel(engine: engine))
        // a launch file (DARKROOM_OPEN or --open=) goes straight to the darkroom
        let launching = DarkroomModel.launchPath(env: ProcessInfo.processInfo.environment) != nil
        _screen = State(initialValue: launching ? .darkroom : .library)
        _welcomed = State(initialValue: launching || UserDefaults.standard.bool(forKey: "darkroom.welcomed"))
    }

    public var body: some View {
        ZStack {
            switch screen {
            case .library: LibraryView(library: library, open: openPhoto)
            case .darkroom: DarkroomView(model: model)
            }
            // the app is Vantage; Darkroom is the editing view, as Develop is in other editors
            Color.clear.frame(width: 0, height: 0)
                .navigationTitle(screen == .darkroom ? "Vantage \u{2014} Darkroom" : "Vantage \u{2014} Library")
            if !welcomed {
                WelcomeView { mode, folder in
                    UserDefaults.standard.set(true, forKey: "darkroom.welcomed")
                    model.mode = mode
                    welcomed = true
                    if let folder { library.load(folder: folder) }
                }
                .transition(.opacity)
            }
        }
        .coordinateSpace(.named("rigRoot"))
        .task {
            model.onBack = { screen = .library; library.paused = false }
            await model.bootstrap()
            Rig.startIfRequested(model: model, library: library, screen: { screen }, go: { screen = $0; library.paused = ($0 == .darkroom) },
                                 open: openPhoto)
            if screen == .library, welcomed, let f = library.restoredFolder { library.load(folder: f) }
            await AutoTest.runIfRequested(model: model)
        }
        .onOpenURL { url in
            if url.isFileURL { openPhoto(url.path) }
        }
    }

    private func openPhoto(_ path: String) {
        library.selected = path   // back in the library, the photo you came from is the selected one
        screen = .darkroom
        library.paused = true   // thumbnails share the engine, so they wait while you edit
        Task { await model.open(path: path) }
    }
}
