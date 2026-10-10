import AppKit
import DarktableKit
import SwiftUI
import UniformTypeIdentifiers

/// Board E: the photo fills the window; modules, scopes, the inspector and history float
/// over it as glass. Every module and every parameter darktable has is reachable.
public struct DarkroomView: View {
    @Bindable var model: DarkroomModel
    @State private var choosing = false

    static let panelWidth: CGFloat = 296
    static let margin: CGFloat = 12

    public init(model: DarkroomModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            PhotoView(model: model)

            VStack(spacing: 0) {
                TopBar(model: model, choosing: $choosing)
                HStack(alignment: .top, spacing: 0) {
                    LeftPanel(model: model)
                        .frame(width: Self.panelWidth)
                    Spacer(minLength: 0)
                    RightColumn(model: model)
                        .frame(width: Self.panelWidth)
                }
                .padding(.top, 12)
                Spacer(minLength: 0)
            }
            .padding(Self.margin)

            VStack {
                Spacer()
                ReadoutBar(model: model)
                    .padding(.bottom, Self.margin)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.rawImage, .image]) { result in
            if case .success(let url) = result { Task { await model.open(path: url.path) } }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in await model.open(path: url.path) } }
            }
            return true
        }
    }
}

// MARK: photo

struct PhotoView: View {
    @Bindable var model: DarkroomModel
    @State private var lastDrag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.black
                if let frame = model.frame {
                    let r = imageRect(frame: frame, in: size)
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .accessibilityLabel("Photo")
                        .accessibilityIdentifier("photo")
                } else {
                    Text(model.status)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("photo-status")
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    guard let f = model.frame else { return }
                    let r = imageRect(frame: f, in: size)
                    guard r.contains(p), r.width > 0 else { model.probe = nil; return }
                    let x = Int((p.x - r.minX) / r.width * CGFloat(f.width))
                    let y = Int((p.y - r.minY) / r.height * CGFloat(f.height))
                    model.probe = model.sample(x: x, y: y)
                case .ended:
                    model.probe = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        guard model.zoom != .fit, let info = model.info else { return }
                        let d = CGSize(width: v.translation.width - lastDrag.width,
                                       height: v.translation.height - lastDrag.height)
                        lastDrag = v.translation
                        let scale = model.displayScale
                        let imgW = Double(info.processedWidth) * scale / model.backingScale
                        let imgH = Double(info.processedHeight) * scale / model.backingScale
                        model.pan(byFraction: CGSize(width: -d.width / imgW, height: -d.height / imgH))
                    }
                    .onEnded { _ in lastDrag = .zero }
            )
            .onAppear { model.viewport = size }
            .onChange(of: size) { _, new in
                model.viewport = new
                if model.zoom != .fit { model.requestRender() }
            }
        }
    }

    /// Where the frame sits in the view, in points.
    func imageRect(frame: CGImage, in size: CGSize) -> CGRect {
        let fw = CGFloat(frame.width), fh = CGFloat(frame.height)
        if model.zoom == .fit {
            // keep clear of the floating panels
            let side = DarkroomView.panelWidth + DarkroomView.margin * 2
            let area = CGRect(x: side, y: 84, width: max(100, size.width - side * 2),
                              height: max(100, size.height - 84 - 72))
            let s = min(area.width / fw, area.height / fh)
            let w = fw * s, h = fh * s
            return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
        }
        let w = fw / model.backingScale, h = fh / model.backingScale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

// MARK: top bar

struct TopBar: View {
    @Bindable var model: DarkroomModel
    @Binding var choosing: Bool

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                fileCapsule
                Spacer(minLength: 8)
                toolsCapsule
                Spacer(minLength: 8)
                exportButton
            }
        }
    }

    private var fileCapsule: some View {
        HStack(spacing: 10) {
            Button { choosing = true } label: {
                Image(systemName: "photo.on.rectangle").frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open image")
            .accessibilityIdentifier("open")

            VStack(alignment: .leading, spacing: 0) {
                Text(model.fileName).font(.callout.weight(.medium)).lineLimit(1)
                Text(model.exifLine.isEmpty ? model.status : model.exifLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        .frame(minWidth: 240, alignment: .leading)
        .glassEffect(.regular, in: .capsule)
    }

    private var toolsCapsule: some View {
        HStack(spacing: 2) {
            // hold to see the original
            Image(systemName: "rectangle.lefthalf.inset.filled")
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .opacity(model.history.count > 1 ? 1 : 0.4)
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, pressing: { down in
                    model.showingOriginal = down && model.history.count > 1
                }, perform: {})
                .accessibilityLabel("Hold to compare with the original")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("compare")

            Menu {
                Button("Take snapshot") { model.takeSnapshot() }
                if model.snapshotEdits != nil {
                    Toggle("Show snapshot", isOn: $model.showingSnapshot)
                    Button("Clear snapshot", role: .destructive) { model.clearSnapshot() }
                }
            } label: {
                Image(systemName: model.snapshotEdits == nil ? "camera" : "camera.fill")
                    .frame(width: 40, height: 40)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Snapshot")
            .accessibilityIdentifier("snapshot")

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 40, height: 40) }
                .buttonStyle(.plain).disabled(!model.canUndo)
                .accessibilityLabel("Undo").accessibilityIdentifier("undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 40, height: 40) }
                .buttonStyle(.plain).disabled(!model.canRedo)
                .accessibilityLabel("Redo").accessibilityIdentifier("redo")

            Divider().frame(height: 22).padding(.horizontal, 6)

            ForEach(ZoomMode.allCases, id: \.self) { z in
                Button { model.zoom = z } label: {
                    Text(z.rawValue)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(model.zoom == z ? Color.white.opacity(0.22) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(z.rawValue)")
                .accessibilityIdentifier("zoom-\(z.rawValue)")
                .accessibilityAddTraits(model.zoom == z ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private var exportButton: some View {
        Button(action: export) {
            Text("Export").font(.callout.weight(.semibold)).padding(.horizontal, 20).padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.orange).interactive(), in: .capsule)
        .disabled(model.frame == nil)
        .accessibilityIdentifier("export")
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
}

// MARK: readout

struct ReadoutBar: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        HStack(spacing: 22) {
            if let p = model.probe {
                let lab = ColorMath.lab(r: p.r, g: p.g, b: p.b)
                readout("sRGB", "\(p.r) \(p.g) \(p.b)")
                readout("Lab", String(format: "%.0f %.0f %.0f", lab.l, lab.a, lab.b))
                readout("x y", "\(p.x) \(p.y)")
            } else {
                readout("sRGB", "– – –")
                readout("Lab", "– – –")
                readout("x y", "– –")
            }
            readout("", model.zoom.rawValue.lowercased())
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 22)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .accessibilityIdentifier("readout")
    }

    private func readout(_ name: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            if !name.isEmpty { Text(name).foregroundStyle(.secondary) }
            Text(value)
        }
    }
}

enum ColorMath {
    /// sRGB (0...255) to CIE Lab, D65.
    static func lab(r: Int, g: Int, b: Int) -> (l: Double, a: Double, b: Double) {
        func lin(_ c: Int) -> Double {
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let R = lin(r), G = lin(g), B = lin(b)
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
