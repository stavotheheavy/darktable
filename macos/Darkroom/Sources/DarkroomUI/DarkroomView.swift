import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Board B: the photo fills the window; one glass capsule at the bottom holds the
/// tools, and the selected tool's sliders morph out of it as a sheet.
public struct DarkroomView: View {
    @Bindable var model: DarkroomModel
    @Namespace private var glass
    @State private var choosing = false

    public init(model: DarkroomModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Color.black

            photo

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.rawImage, .image]) { result in
            if case .success(let url) = result { Task { await model.open(path: url.path) } }
        }
    }

    // MARK: photo

    @ViewBuilder
    private var photo: some View {
        let shown = model.showingOriginal ? (model.original ?? model.image) : model.image
        if let shown {
            Image(decorative: shown, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(model.status)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: top

    private var topBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Button { choosing = true } label: {
                        Image(systemName: "photo.on.rectangle")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open image")

                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.fileName).font(.callout.weight(.medium))
                        Text(statusLine).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 20)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)

                Spacer()

                HStack(spacing: 8) {
                    Button {} label: {
                        Image(systemName: "rectangle.lefthalf.inset.filled")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in if model.isEdited { model.showingOriginal = true } }
                            .onEnded { _ in model.showingOriginal = false })
                    .disabled(!model.isEdited)
                    .accessibilityLabel("Hold to compare with the original")

                    Button(action: export) {
                        Text("Export").font(.callout.weight(.semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.orange).interactive(), in: .capsule)
                    .disabled(model.image == nil)
                }
            }
        }
    }

    private var statusLine: String {
        if let ms = model.lastMilliseconds { return "\(model.status)  ·  \(Int(ms)) ms" }
        return model.status
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        let stem = URL(fileURLWithPath: model.fileName).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = stem + ".jpg"
        panel.begin { response in
            if response == .OK, let url = panel.url { Task { await model.export(to: url) } }
        }
    }

    // MARK: bottom

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 12) {
                if let tool = model.openTool {
                    sheet(for: tool)
                        .glassEffect(.regular, in: .rect(cornerRadius: 30))
                        .glassEffectID("sheet", in: glass)
                }
                toolRow
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("bar", in: glass)
            }
        }
        .frame(maxWidth: 780)
        .animation(.smooth(duration: 0.4), value: model.openTool)
    }

    private var toolRow: some View {
        HStack(spacing: 6) {
            ForEach(Tool.allCases) { tool in
                let selected = model.openTool == tool
                Button { model.toggle(tool) } label: {
                    Label(tool.title, systemImage: tool.symbol)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    selected ? .regular.tint(.orange).interactive() : .regular.interactive(),
                    in: .capsule)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(6)
    }

    private func sheet(for tool: Tool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tool.title).font(.title3.weight(.semibold))
                Spacer()
                Button("Reset") { model.reset(tool) }
                    .buttonStyle(.glass)
                    .disabled(!tool.sliders.contains { model.touched.contains($0.id) })
                Button { model.openTool = nil } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Collapse \(tool.title)")
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 22), count: 3),
                alignment: .leading, spacing: 10
            ) {
                ForEach(tool.sliders) { spec in
                    SliderCell(model: model, spec: spec)
                }
            }
        }
        .padding(18)
    }
}

struct SliderCell: View {
    @Bindable var model: DarkroomModel
    let spec: SliderSpec

    var body: some View {
        let touched = model.touched.contains(spec.id)
        VStack(spacing: 2) {
            HStack {
                Text(spec.label).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(spec.display(model.value(for: spec)))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(touched ? Color.orange : Color.primary)
            }
            Slider(
                value: Binding(
                    get: { model.value(for: spec) },
                    set: { model.set(spec, to: $0) }),
                in: spec.range
            ) { editing in
                if editing { model.beginScrub() } else { model.endScrub() }
            }
            .tint(.orange)
            .accessibilityLabel(spec.label)
        }
    }
}

/// The window's root: owns the model and starts the engine.
public struct DarkroomRoot: View {
    @State private var model = DarkroomModel()

    public init() {}

    public var body: some View {
        DarkroomView(model: model)
            .task { await model.bootstrap() }
    }
}
