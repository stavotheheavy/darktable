import DarkroomEngineAPI
import SwiftUI

/// The iPhone's darkroom: the photo centered, glass tools floating round it, a tray of tools along the bottom, and one
/// large control that pops up when a tool is tapped. It runs on Simple mode's controls (the phone has no Pro panel), so a
/// tool in the tray is a Simple slider, the looks, white balance, or crop and straighten.
struct PhoneEditView: View {
    @Bindable var model: DarkroomModel
    @Binding var choosing: Bool
    @State private var open: PhoneTool?

    enum PhoneTool: Hashable, Identifiable {
        case looks
        case control(SimpleControl)
        case whiteBalance
        case crop

        var id: String {
            switch self {
            case .looks: "looks"
            case .control(let c): c.rawValue.lowercased()
            case .whiteBalance: "white-balance"
            case .crop: "crop"
            }
        }

        var title: String {
            switch self {
            case .looks: "Looks"
            case .control(let c): c.rawValue
            case .whiteBalance: "White balance"
            case .crop: "Crop"
            }
        }

        /// The tray label, short enough to sit in a tile.
        var short: String {
            switch self {
            case .whiteBalance: "Balance"
            default: title
            }
        }

        var symbol: String {
            switch self {
            case .looks: "sparkles"
            case .control: "slider.horizontal.3"
            case .whiteBalance: "thermometer.medium"
            case .crop: "crop.rotate"
            }
        }
    }

    private var tools: [PhoneTool] {
        [.looks] + model.simpleControls.map(PhoneTool.control) + [.whiteBalance, .crop]
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                PhotoView(model: model)

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                }
                .padding(DarkroomView.margin)

                rails(landscape: landscape)

                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if let tool = open {
                        controls(for: tool, compact: landscape)
                            // while a slider is being dragged the card steps back so the photo can be judged
                            .opacity(model.dragging ? 0.35 : 1)
                            .animation(.easeOut(duration: 0.15), value: model.dragging)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            // a cancelled touch (Control Center, a call) never reports "let go"; a card that opens or
                            // goes away must not inherit a drag that is no longer happening
                            .onDisappear { model.setDragging(false) }
                    }
                    tray(landscape: landscape)
                }
                .padding(DarkroomView.margin)
                .chrome(hidden: model.uiHidden)
                .animation(.snappy(duration: 0.22), value: open)
            }
        }
        .onChange(of: open) { _, _ in model.setDragging(false) }
        .task(id: model.modules.count) { await model.prepareSimple() }
    }

    // MARK: top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            if model.onBack != nil {
                glassIcon("chevron.left", label: "Back to the library", id: "back") { model.onBack?() }
                    .chrome(hidden: model.uiHidden)
            }
            Spacer(minLength: 0)
            // Hide UI and Export stay on screen when the rest fades, so the photo can be seen whole and shown again
            HStack(spacing: 4) {
                Button { model.uiHidden.toggle() } label: {
                    Image(systemName: model.uiHidden ? "eye" : "rectangle.split.3x1")
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.uiHidden ? "Show UI" : "Hide UI")
                .rig("hide-ui")
                Button { DarkroomExport.start(model) } label: { Text("Export").lineLimit(1).fixedSize() }
                    .buttonStyle(PrimaryCapsuleStyle())
                    .disabled(model.frame == nil)
                    .rig("export")
            }
            .padding(6)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private func glassIcon(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .rig(id)
        .padding(6)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: rails

    /// Portrait: the zoom and edit tools are two clusters in a row under the top bar, above the photo. Landscape: the same
    /// clusters stand upright at the two sides, with the photo between them. Either way they never sit on the photo.
    private func rails(landscape: Bool) -> some View {
        let layout = landscape ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        let size: CGFloat = landscape ? 40 : 44
        return HStack(alignment: .top) {
            layout {
                railButton("plus", label: "Zoom in", id: "zoom-in", size: size) { withAnimation(.snappy) { model.zoomCanvas(by: 1.5) } }
                railButton("minus", label: "Zoom out", id: "zoom-out", size: size) { withAnimation(.snappy) { model.zoomCanvas(by: 1 / 1.5) } }
                railButton("arrow.up.left.and.arrow.down.right", label: "Fit the photo", id: "zoom-fit", size: size) { withAnimation(.snappy) { model.resetCanvas() } }
            }
            .padding(6)
            .glassEffect(.regular, in: .capsule)
            Spacer(minLength: 0)
            layout {
                railButton("arrow.uturn.backward", label: "Undo", id: "undo", size: size) { model.undo() }
                    .disabled(!model.canUndo)
                railButton("arrow.uturn.forward", label: "Redo", id: "redo", size: size) { model.redo() }
                    .disabled(!model.canRedo)
                railButton("wand.and.stars", label: "Auto edit", id: "auto-edit", size: size) { Task { await model.autoEdit() } }
                    .disabled(model.autoEditing || model.filePath == nil)
                railButton("circle.lefthalf.filled", label: "Show the original", id: "original", size: size) { model.showingOriginal.toggle() }
                    .disabled(model.history.count <= 1)
            }
            .padding(6)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, DarkroomView.margin)
        .padding(.top, landscape ? 76 : 80)
        .frame(maxHeight: .infinity, alignment: .top)
        // in landscape a control that is open needs the whole height, so the rails step aside
        .chrome(hidden: model.uiHidden || (landscape && open != nil))
    }

    private func railButton(_ symbol: String, label: String, id: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: size, height: size).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .rig(id)
    }

    // MARK: tray

    private func tray(landscape: Bool) -> some View {
        ZStack {
            // the glass is its own layer, so the tiles can be clipped to its edge and faded at the ends
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 28))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tools) { tool in
                        Button { open = open == tool ? nil : tool } label: { tile(tool) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tool.title)
                            .accessibilityAddTraits(open == tool ? .isSelected : [])
                            .rig("phone-tool-\(tool.id)")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                       .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
        }
        .frame(height: landscape ? 88 : 100)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .disabled(!model.simpleReady)
        .opacity(model.simpleReady ? 1 : 0.5)
    }

    private func tile(_ tool: PhoneTool) -> some View {
        let on = open == tool
        return VStack(spacing: 4) {
            if case .control(let c) = tool {
                Text(String(format: "%+.0f", model.simpleValue(c)))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .frame(height: 24)
            } else {
                Image(systemName: tool.symbol).font(.system(size: 18, weight: .medium)).frame(height: 24)
            }
            Text(tool.short).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 70, height: 62)
        // flat fills inside the glass: a faint wash at rest, the accent wash and a thin ring when open
        .background(on ? Theme.selectedFill : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay { if on { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.selectedRing, lineWidth: 1) } }
        .foregroundStyle(on ? Theme.accent : .primary)
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: the control that pops up

    @ViewBuilder
    private func controls(for tool: PhoneTool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 12) {
            HStack {
                Text(tool.title).font(.title3.weight(.semibold))
                Spacer()
                if case .control(let c) = tool {
                    Text(String(format: "%+.0f", model.simpleValue(c))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                if case .control(let c) = tool {
                    Button("Reset") { model.setSimple(c, to: min(max(0, c.range.lowerBound), c.range.upperBound)) }
                        .buttonStyle(FlatCapsuleStyle())
                        .rig("phone-reset")
                }
                Button("Done") { open = nil }
                    .buttonStyle(FlatCapsuleStyle())
                    .rig("phone-done")
            }
            switch tool {
            case .looks:
                LooksRow(model: model)
            case .control(let c):
                Slider(value: Binding(get: { model.simpleValue(c) }, set: { model.setSimple(c, to: $0) }),
                       in: c.range, step: 1)
                    .modifier(DragTracking(model: model))
                    .tint(Theme.accent)
                    .frame(height: compact ? 32 : 44)
                    .accessibilityLabel(c.rawValue)
                    .rig("phone-slider")
            case .whiteBalance:
                AutoWhiteBalanceButton(model: model, id: "phone-awb")
            case .crop:
                cropControls
            }
        }
        .padding(compact ? 12 : 18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var cropControls: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Straighten").font(.callout.weight(.medium))
                Spacer()
                Text(String(format: "%+.1f°", model.simpleStraighten)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { model.simpleStraighten }, set: { model.setStraighten($0) }),
                   in: DarkroomModel.straightenRange, step: 0.1)
                .modifier(DragTracking(model: model))
                .tint(Theme.accent)
                .frame(height: 44)
                .accessibilityLabel("Straighten")
                .rig("phone-straighten")
            Button { model.rotate90() } label: {
                Label("Rotate 90°", systemImage: "rotate.right")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rotate 90 degrees clockwise")
            .rig("phone-rotate")
            HStack(spacing: 6) {
                ForEach(SimpleAspect.allCases) { a in
                    Button { model.setAspect(a) } label: {
                        Text(a.rawValue)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(Color.white.opacity(model.simpleAspect == a ? 0.26 : 0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a.spoken)
                    .rig("phone-aspect-\(a.slug)")
                }
            }
        }
        .disabled(!model.simpleGeometryReady)
        .opacity(model.simpleGeometryReady ? 1 : 0.5)
    }
}

/// Export from the iPad and iPhone: a JPEG written to the temporary folder for now; the share sheet comes later.
enum DarkroomExport {
    @MainActor static func start(_ model: DarkroomModel) {
        let stem = URL(fileURLWithPath: model.fileName).deletingPathExtension().lastPathComponent
        let url = FileManager.default.temporaryDirectory.appending(path: stem + ".jpg")
        Task { await model.export(to: url, hdr: false) }
    }
}

/// Tells the model a slider is held, from the touch itself. `Slider.onEditingChanged` can miss the "let go"
/// (a cancelled touch, a card that closes mid-drag), which left the card dimmed and the engine on draft frames;
/// a GestureState goes back to false on end and on cancel, so it cannot stick.
private struct DragTracking: ViewModifier {
    let model: DarkroomModel
    @GestureState private var held = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($held) { _, state, _ in state = true })
            .onChange(of: held) { _, on in model.setDragging(on) }
    }
}
