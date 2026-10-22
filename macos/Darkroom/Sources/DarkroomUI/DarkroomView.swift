import DarkroomEngineAPI
#if os(macOS)
import DarktableKit
#endif
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
                if model.mode == .pro {
                    // modules come from the header's Modules menu; the panel holds the ones in use
                    HStack(alignment: .top, spacing: 0) {
                        if model.libraryShown { ToolLibrary(model: model) }
                        Spacer(minLength: 0)
                        ProPanel(model: model)
                            .frame(width: Self.panelWidth)
                    }
                    .padding(.top, 12)
                    .chrome(hidden: model.uiHidden)
                }
                Spacer(minLength: 0)
            }
            .padding(Self.margin)

            if model.mode == .pro {
                VStack {
                    Spacer()
                    ReadoutBar(model: model)
                        .padding(.bottom, Self.margin)
                }
                .chrome(hidden: model.uiHidden)
            } else {
                SimpleChrome(model: model)
                    .chrome(hidden: model.uiHidden)
            }

            // keyboard routes, every one from the registry (Shortcuts.swift): instant, because a key that is pressed
            // often should not animate
            Group {
                ForEach(Shortcuts.all.filter { !$0.viaRouter }) { s in
                    Button("") { s.action(model) }.keyboardShortcut(s.shortcut)
                }
            }
            .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
            .onAppear { KeyRouter.install(for: model); Task { await model.refreshCloud() } }

            if model.helpShown { HelpOverlay(model: model).transition(.opacity) }
        }
        .overlayPreferenceValue(ProMenuAnchorKey.self) { anchors in
            // the open Pro dropdown, right under its header button; a click anywhere else, or Escape, closes it
            GeometryReader { geo in
                if let kind = model.proMenuOpen, model.mode == .pro, !model.uiHidden, let anchor = anchors[kind] {
                    let r = geo[anchor], w = ProDropdown.width(kind)
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { model.proMenuOpen = nil }
                        ProDropdown(model: model, kind: kind)
                            .offset(x: min(max(r.minX, Self.margin), geo.size.width - w - Self.margin), y: r.maxY + 8)
                            .transition(.opacity)
                    }
                }
            }
            .animation(.easeOut(duration: 0.12), value: model.proMenuOpen)
        }
        .onChange(of: model.mode) { _, _ in model.proMenuOpen = nil }
        .background(model.backdrop.color)
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

extension View {
    /// Fades the floating panels out for Hide UI. The fade is opacity only (220 ms ease-out);
    /// hidden panels also stop taking clicks.
    func chrome(hidden: Bool) -> some View {
        self.opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22), value: hidden)
    }
}

// MARK: photo

struct PhotoView: View {
    @Bindable var model: DarkroomModel
    @State private var lastDrag: CGSize = .zero
    /// The stroke being painted, in view points, until the finger lifts.
    @State private var live: [CGPoint] = []

    /// The canvas presents the engine's frames as Metal textures unless DARKROOM_NO_METAL_CANVAS is set.
    private static let metalCanvas = ProcessInfo.processInfo.environment["DARKROOM_NO_METAL_CANVAS"] == nil

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                BackdropView(style: model.backdrop)
                if let frame = model.frame {
                    let r = imageRect(frame: frame, in: size)
                    canvasPicture(frame)
                        .frame(width: r.width, height: r.height)
                        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 26, y: 10)
                        .overlay { liveStroke(r) }
                        .position(x: r.midX, y: r.midY)
                        .accessibilityLabel("Photo")
                        .rig("photo")
                    if model.cropEditing { CropOverlay(model: model, photo: r) }
                } else {
                    Text(model.status)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .rig("photo-status")
                }
            }
            .contentShape(Rectangle())
            .onAppear {
                if Self.metalCanvas, !model.presentsTexture { model.presentsTexture = true; model.requestRender() }
            }
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
            .highPriorityGesture(paintGesture(in: size), including: model.paintModuleID != nil && model.canPaint ? .all : .none)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        guard model.zoom != .fit, let image = model.imageSize else { return }
                        let d = CGSize(width: v.translation.width - lastDrag.width,
                                       height: v.translation.height - lastDrag.height)
                        lastDrag = v.translation
                        let scale = model.displayScale
                        let imgW = Double(image.width) * scale / model.backingScale
                        let imgH = Double(image.height) * scale / model.backingScale
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

    /// What is being drawn under the finger until it is committed: the brush stroke (white, soft), or the shape's outline.
    @ViewBuilder private func liveStroke(_ r: CGRect) -> some View {
        if !live.isEmpty {
            let pts = live.map { CGPoint(x: $0.x - r.minX, y: $0.y - r.minY) }
            let tool = model.paintTool
            Group {
                if tool == .brush {
                    let width = model.brushRadius * hypot(r.width, r.height) * 2
                    Path { p in
                        p.move(to: pts[0])
                        if pts.count == 1 { p.addLine(to: pts[0]) } else { p.addLines(Array(pts.dropFirst())) }
                    }
                    .stroke(Color.white.opacity(model.brushErase ? 0.25 : 0.55), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                } else {
                    Path { p in
                        let a = pts[0], b = pts[pts.count - 1]
                        switch tool {
                        case .lasso: p.move(to: a); p.addLines(Array(pts.dropFirst())); p.closeSubpath()
                        case .linear: p.move(to: a); p.addLine(to: b)
                        default: p.addEllipse(in: CGRect(x: a.x - abs(b.x - a.x), y: a.y - abs(b.y - a.y), width: 2 * abs(b.x - a.x), height: 2 * abs(b.y - a.y)))
                        }
                    }
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [6, 4]))
                }
            }
            .frame(width: r.width, height: r.height, alignment: .topLeading)
            .clipped()
            .allowsHitTesting(false)
        }
    }

    private func paintGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard let f = model.frame else { return }
                let r = imageRect(frame: f, in: size)
                let p = CGPoint(x: min(max(v.location.x, r.minX), r.maxX), y: min(max(v.location.y, r.minY), r.maxY))
                if live.last.map({ hypot($0.x - p.x, $0.y - p.y) > 1.5 }) ?? true { live.append(p) }
            }
            .onEnded { _ in
                defer { live = [] }
                guard let f = model.frame, !live.isEmpty else { return }
                let r = imageRect(frame: f, in: size)
                guard r.width > 0, r.height > 0 else { return }
                let unit = live.map { CGPoint(x: ($0.x - r.minX) / r.width, y: ($0.y - r.minY) / r.height) }
                if model.paintTool == .brush { model.paintStroke(unit) } else { model.drawShape(unit) }
            }
    }

    /// Where the frame sits in the view, in points.
    /// The picture: a Metal layer presenting the engine's 16-bit texture when the model has one, else the 8-bit image.
    @ViewBuilder
    private func canvasPicture(_ frame: CGImage) -> some View {
        if let presented = model.frameTexture {
            MetalFrameView(frame: presented, serial: model.frameSerial)
        } else {
            Image(decorative: frame, scale: 1)
                .resizable()
                .interpolation(.high)
        }
    }

    func imageRect(frame: CGImage, in size: CGSize) -> CGRect {
        // a presented frame's CGImage is a thumbnail: the picture's own size lays it out
        let fw = model.frameSize?.width ?? CGFloat(frame.width), fh = model.frameSize?.height ?? CGFloat(frame.height)
        if model.zoom == .fit {
            // keep clear of the floating panels
            let side = DarkroomView.panelWidth + DarkroomView.margin * 2
            // Simple has one panel on the right and a row of looks along the bottom
            let simple = model.mode == .simple
            let left = simple || !model.libraryShown ? DarkroomView.margin * 2 : ToolLibrary.width + DarkroomView.margin * 2
            let bottom: CGFloat = simple ? 140 : 72
            let area = CGRect(x: left, y: 84, width: max(100, size.width - left - side),
                              height: max(100, size.height - 84 - bottom))
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
            // the first layout that fits wins; at the narrowest window the zoom group and the
            // button labels give way instead of wrapping or clipping
            ViewThatFits(in: .horizontal) {
                row(compact: false, menuWords: true)
                // the zoom group and side labels give way before the Pro menus lose their words
                row(compact: true, menuWords: true)
                row(compact: true, menuWords: false)
            }
        }
    }

    private func row(compact: Bool, menuWords: Bool) -> some View {
        HStack(spacing: 12) {
            fileCapsule.chrome(hidden: model.uiHidden)
            ModeSwitch(model: model).chrome(hidden: model.uiHidden)
            if model.mode == .pro { ProMenus(model: model, compact: !menuWords).chrome(hidden: model.uiHidden) }
            Spacer(minLength: 8)
            toolsCapsule(compact: compact).chrome(hidden: model.uiHidden)
            Spacer(minLength: 8)
            rightGroup(compact: compact)
        }
    }

    private var fileCapsule: some View {
        HStack(spacing: 10) {
            if let back = model.onBack {
                Button(action: back) { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to the library")
                    .rig("back")
            }
            Button { choosing = true } label: {
                Image(systemName: "photo.on.rectangle").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open image")
            .rig("open")

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
        .frame(minWidth: 200, alignment: .leading)
        .glassEffect(.regular, in: .capsule)
    }

    private func toolsCapsule(compact: Bool) -> some View {
        HStack(spacing: 2) {
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
            .rig("snapshot")

            Button { Task { await model.autoEdit() } } label: {
                Image(systemName: "wand.and.stars").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.autoEditing || model.filePath == nil)
            .help("Auto edit: white balance, exposure, highlights, shadows (A)")
            .accessibilityLabel("Auto edit").rig("auto-edit")

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(!model.canUndo)
                .accessibilityLabel("Undo").rig("undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(!model.canRedo)
                .accessibilityLabel("Redo").rig("redo")

            AccountMenu(model: model)

            BackdropMenu(model: model)

            // the crop tool (Pro): crop, straighten, turn and flip, in a dropdown under this button (CropTool.swift)
            if model.mode == .pro {
                let open = model.proMenuOpen == .crop
                Button { model.proMenuOpen = open ? nil : .crop } label: {
                    Image(systemName: "crop.rotate")
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(open ? Color.white.opacity(0.14) : .clear, in: Circle())
                .anchorPreference(key: ProMenuAnchorKey.self, value: .bounds) { [ProMenuKind.crop: $0] }
                .help("Crop, straighten, turn and flip (C)")
                .accessibilityLabel("Crop and straighten")
                .accessibilityAddTraits(open ? .isSelected : [])
                .rig("crop-tool")
            }

            // the mask tools (Pro): brush, lasso, linear and radial selections drawn on the photo; each goes on the open section
            if model.mode == .pro {
                Menu {
                    ForEach([MaskLayerKind.brush, .lasso, .linear, .radial], id: \.self) { k in
                        Button { Task { await model.applyLibraryMask(k) } } label: { Label(k.title.capitalized, systemImage: k.symbol) }
                    }
                } label: {
                    Image(systemName: model.paintModuleID != nil ? "lasso.badge.sparkles" : "lasso")
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .background(model.paintModuleID != nil ? Color.white.opacity(0.14) : .clear, in: Circle())
                .help("Mask tools: brush (B), lasso (L), linear gradient (G), radial (R)")
                .accessibilityLabel("Mask tools")
                .rig("mask-tools")
            }

            // HDR preview: only where a screen has headroom above SDR white
            if model.hdrAvailable {
                Button { model.setHDRPreview(!model.hdrPreview) } label: {
                    Image(systemName: model.hdrPreview ? "sun.max.fill" : "sun.max")
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("HDR preview: show highlights brighter than the page on this display")
                .accessibilityLabel(model.hdrPreview ? "HDR preview on" : "HDR preview off")
                .rig("hdr")
            }

            if !compact {
            Divider().frame(height: 22).padding(.horizontal, 6)

            ForEach(ZoomMode.allCases, id: \.self) { z in
                Button { model.zoom = z } label: {
                    Text(z.rawValue)
                        .font(.callout.weight(.medium))
                        // never truncated: when the row is too tight ViewThatFits drops the whole zoom group instead
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(model.zoom == z ? Color.white.opacity(0.22) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(z.rawValue)")
                .rig("zoom-\(z.rawValue)")
                .accessibilityAddTraits(model.zoom == z ? .isSelected : [])
            }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    /// Hide UI, Original and Export. This group stays visible when the panels fade, so the
    /// way back is always on screen.
    private func rightGroup(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                model.uiHidden.toggle()
            } label: {
                if compact { Image(systemName: model.uiHidden ? "eye" : "rectangle.split.3x1") }
                else { Label(model.uiHidden ? "Show UI" : "Hide UI", systemImage: model.uiHidden ? "eye" : "rectangle.split.3x1") }
            }
            .buttonStyle(FlatCapsuleStyle(on: model.uiHidden))
            .rig("hide-ui")

            Button {
                model.showingOriginal.toggle()
            } label: {
                if compact { Image(systemName: "arrow.uturn.backward") } else { Label("Original", systemImage: "arrow.uturn.backward") }
            }
            .buttonStyle(FlatCapsuleStyle(on: model.showingOriginal))
            .disabled(model.history.count <= 1)
            .accessibilityLabel("Show the original")
            .rig("original")

            if Rig.canary("smalltarget") {
                Button { } label: { Image(systemName: "gearshape").font(.system(size: 9)) }.buttonStyle(.plain).frame(width: 14, height: 14).rig("canary-gear")
            }
            Button(action: export) { Text("Export").lineLimit(1).fixedSize() }
                .buttonStyle(PrimaryCapsuleStyle())
                .disabled(model.frame == nil)
                .rig("export")
        }
        .padding(8)
        .glassEffect(.regular, in: .capsule)
    }

    private func export() {
        #if os(macOS)
        exportWithPanel()
        #else
        // iPad and iPhone: write a JPEG to the temporary folder for now; the share sheet comes with the touch UI.
        let stem = URL(fileURLWithPath: model.fileName).deletingPathExtension().lastPathComponent
        let url = FileManager.default.temporaryDirectory.appending(path: stem + ".jpg")
        Task { await model.export(to: url, hdr: false) }
        #endif
    }

    #if os(macOS)
    private func exportWithPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        let stem = URL(fileURLWithPath: model.fileName).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = stem + ".jpg"
        // an optional HDR gain map: a viewer that knows it shows highlights past white, any other shows the same picture.
        // Remembered between exports; the clean engine writes it, the darktable engine cannot (the box is then ignored).
        let key = "exportHDRGainMap"
        let box = NSButton(checkboxWithTitle: "Include HDR gain map (highlights up to 4x white)", target: nil, action: nil)
        box.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 36))
        box.frame = NSRect(x: 12, y: 8, width: 400, height: 20)
        holder.addSubview(box)
        panel.accessoryView = holder
        panel.begin { response in
            let hdr = box.state == .on
            if response == .OK { UserDefaults.standard.set(hdr, forKey: key) }
            if response == .OK, let url = panel.url { Task { await model.export(to: url, hdr: hdr) } }
        }
    }
    #endif
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
        .rig("readout")
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

