import DarktableKit
import SwiftUI

/// Simple and Pro are two doors into one engine (canvas board S2). Simple writes the real
/// module parameters, so a photo edited here opens in Pro with every change in place.
public enum EditMode: String, CaseIterable, Sendable {
    case simple = "Simple", pro = "Pro"

    static let key = "darkroom.mode"
    static func load() -> EditMode {
        EditMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .pro
    }
}

public enum SimpleControl: String, CaseIterable, Identifiable, Sendable {
    case light = "Light", shadows = "Shadows", highlights = "Highlights", contrast = "Contrast", color = "Color", warmth = "Warmth", detail = "Detail"
    public var id: String { rawValue }
    /// Shadows and Highlights are the zone exposure module's; the darktable engine has no such module, so Simple leaves them out there.
    var module: String? { self == .shadows || self == .highlights ? "zones" : nil }
    /// Detail only sharpens; the others run both ways.
    var range: ClosedRange<Double> { self == .detail ? 0...100 : -100...100 }
}

/// A look is five slider positions, so applying one is the same as dragging five sliders.
public struct SimpleLook: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let values: [SimpleControl: Double]
    let swatch: [Color]

    public static let all: [SimpleLook] = [
        SimpleLook(id: "auto", name: "Auto",
                   values: [.light: 18, .contrast: 14, .color: 12, .warmth: 4, .detail: 20],
                   swatch: [Color(red: 0.29, green: 0.36, blue: 0.54), Color(red: 0.89, green: 0.63, blue: 0.48)]),
        SimpleLook(id: "warm", name: "Warm",
                   values: [.light: 6, .contrast: 8, .color: 18, .warmth: 55, .detail: 0],
                   swatch: [Color(red: 0.54, green: 0.35, blue: 0.23), Color(red: 1, green: 0.72, blue: 0.42)]),
        SimpleLook(id: "cool", name: "Cool",
                   values: [.light: 0, .contrast: 10, .color: 6, .warmth: -50, .detail: 8],
                   swatch: [Color(red: 0.15, green: 0.25, blue: 0.48), Color(red: 0.6, green: 0.82, blue: 1)]),
        SimpleLook(id: "punch", name: "Punchy",
                   values: [.light: 10, .contrast: 42, .color: 44, .warmth: 6, .detail: 36],
                   swatch: [Color(red: 0.42, green: 0.12, blue: 0.42), Color(red: 1, green: 0.48, blue: 0.23)]),
        SimpleLook(id: "soft", name: "Soft",
                   values: [.light: 14, .contrast: -16, .color: -10, .warmth: 12, .detail: 0],
                   swatch: [Color(red: 0.42, green: 0.38, blue: 0.47), Color(red: 0.91, green: 0.82, blue: 0.82)]),
        SimpleLook(id: "bw", name: "B&W",
                   values: [.light: 4, .contrast: 24, .color: -100, .warmth: 0, .detail: 24],
                   swatch: [Color(white: 0.07), Color(white: 0.87)]),
    ]
}

// MARK: mapping to modules

extension DarkroomModel {
    static let simpleOperations = ["exposure", "colorbalancergb", "temperature", "sharpen"]
    /// Modules a Simple slider drives when the engine has them (the zone exposure behind Shadows and Highlights).
    static let simpleOptionalOperations = ["zones"]

    /// The sliders this engine can drive.
    public var simpleControls: [SimpleControl] {
        SimpleControl.allCases.filter { c in c.module.map { module($0) != nil } ?? true }
    }

    func module(_ operation: String) -> ModuleInfo? { modules.first { $0.operation == operation } }

    func field(_ operation: String, _ name: String) -> (ModuleInfo, FieldSchema)? {
        guard let m = module(operation), let f = schemas[operation]?.fields.first(where: { $0.name == name })
        else { return nil }
        return (m, f)
    }

    /// Schemas arrive lazily; Simple needs a handful of them before its sliders mean anything.
    public func prepareSimple() async {
        for op in Self.simpleOperations + Self.simpleOptionalOperations + Self.simpleGeometryOperations { if let m = module(op) { await loadSchema(for: m) } }
    }

    public var simpleReady: Bool {
        Self.simpleOperations.allSatisfy { field($0, Self.primaryField[$0] ?? "") != nil }
    }

    private static let primaryField = ["exposure": "exposure", "colorbalancergb": "contrast",
                                       "temperature": "red", "sharpen": "amount"]

    private func number(_ operation: String, _ name: String) -> Double? {
        guard let (m, f) = field(operation, name) else { return nil }
        return value(m, f).double
    }

    private func write(_ operation: String, _ name: String, _ v: Double) {
        guard let (m, f) = field(operation, name) else { return }
        setParam(m, f, to: .number(v))
    }

    /// Where the slider sits, read back from the real parameters so Pro edits show up here.
    public func simpleValue(_ c: SimpleControl) -> Double {
        let v: Double
        switch c {
        case .light:
            v = (number("exposure", "exposure") ?? 0) / 2 * 100
        case .shadows:
            guard let z = module("zones"), isEnabled(z) else { return 0 }
            v = (number("zones", "shadows") ?? 0) / 2 * 100
        case .highlights:
            guard let z = module("zones"), isEnabled(z) else { return 0 }
            v = (number("zones", "highlights") ?? 0) / 2 * 100
        case .contrast:
            v = (number("colorbalancergb", "contrast") ?? 0) / 0.5 * 100
        case .color:
            v = (number("colorbalancergb", "vibrance") ?? 0) / 0.6 * 100
        case .warmth:
            guard let (m, f) = field("temperature", "red"), let red = value(m, f).double,
                  let base = base(m, f).double, base > 0 else { return 0 }
            v = (red / base - 1) / 0.25 * 100
        case .detail:
            guard let s = module("sharpen"), isEnabled(s) else { return 0 }
            v = (number("sharpen", "amount") ?? 0) / 1.2 * 100
        }
        return min(max(v, c.range.lowerBound), c.range.upperBound)
    }

    public func setSimple(_ c: SimpleControl, to v: Double) {
        grouped(c.rawValue, target: "simple.\(c.rawValue)") { writeSimple(c, to: v) }
    }

    /// Auto white balance: the engine measures grey-world gains on the open photo and they become the white balance module's red, green and blue,
    /// as one undo step. A photo with nothing reliable to measure gets unit gains, which is no change.
    public func autoWhiteBalance() async {
        guard let gains = await measureAutoWhiteBalance(), gains.count == 3,
              let (m, fr) = field("temperature", "red"), let (_, fg) = field("temperature", "green"), let (_, fb) = field("temperature", "blue"),
              let r = base(m, fr).double, let g = base(m, fg).double, let b = base(m, fb).double else { return }
        grouped("Auto white balance", target: "awb") {
            write("temperature", "red", r * gains[0])
            write("temperature", "green", g * gains[1])
            write("temperature", "blue", b * gains[2])
        }
    }

    private func writeSimple(_ c: SimpleControl, to v: Double) {
        let v = min(max(v, c.range.lowerBound), c.range.upperBound)
        switch c {
        case .light:
            write("exposure", "exposure", v / 100 * 2)
        case .shadows, .highlights:
            guard let z = module("zones") else { return }
            // 100 on the slider is two stops at the zones the control reaches; the module is on while either slider is off zero
            write("zones", c == .shadows ? "shadows" : "highlights", v / 100 * 2)
            let other = c == .shadows ? "highlights" : "shadows"
            let on = v != 0 || (number("zones", other) ?? 0) != 0
            if on != isEnabled(z) { setEnabled(z, on) }
        case .contrast:
            write("colorbalancergb", "contrast", v / 100 * 0.5)
        case .color:
            write("colorbalancergb", "vibrance", v / 100 * 0.6)
            // below zero the picture goes grey; above it, saturation stays gentle
            write("colorbalancergb", "saturation_global", v < 0 ? v / 100 : v / 100 * 0.4)
        case .warmth:
            guard let (m, fr) = field("temperature", "red"), let (_, fb) = field("temperature", "blue"),
                  let r = base(m, fr).double, let b = base(m, fb).double else { return }
            let w = v / 100 * 0.25
            write("temperature", "red", r * (1 + w))
            write("temperature", "blue", b * (1 - w))
        case .detail:
            guard let s = module("sharpen") else { return }
            if v <= 0 {
                if isEnabled(s) { setEnabled(s, false) }
            } else {
                write("sharpen", "amount", v / 100 * 1.2)
                if !isEnabled(s) { setEnabled(s, true) }
            }
        }
    }

    public func apply(_ look: SimpleLook) {
        grouped(look.name, target: "look.\(look.id)") {
            for c in SimpleControl.allCases { writeSimple(c, to: look.values[c] ?? 0) }
        }
    }

    /// True when something other than this slider has changed the module behind it, in Pro:
    /// another parameter on the same module, or a mask or blend. The slider then shows a dot.
    public func simpleTouchedByPro(_ c: SimpleControl) -> Bool {
        let (op, owned): (String, Set<String>) = switch c {
        case .light: ("exposure", ["exposure"])
        case .shadows, .highlights: ("zones", ["shadows", "highlights"])
        case .contrast, .color: ("colorbalancergb", ["contrast", "vibrance", "saturation_global"])
        case .warmth: ("temperature", ["red", "blue"])
        case .detail: ("sharpen", ["amount"])
        }
        guard let m = module(op), let e = edits[m.id] else { return false }
        return !Set(e.params.keys).subtracting(owned).isEmpty || !e.blend.isEmpty
    }

    /// Edited modules Simple has no slider for, so the panel can say what Pro changed.
    public var customEditCount: Int {
        moduleRows.filter {
            $0.edited && !Self.simpleOperations.contains($0.module.operation) && !Self.simpleOptionalOperations.contains($0.module.operation) && !Self.simpleGeometryOperations.contains($0.module.operation)
        }.count
    }
}

// MARK: views

struct SimpleChrome: View {
    @Bindable var model: DarkroomModel

    static let panelWidth: CGFloat = 316

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .top) {
                Spacer(minLength: 0)
                // the looks live inside the panel, so nothing floats over the photo or the controls;
                // past the window's height the controls scroll
                SimplePanel(model: model, maxHeight: max(160, geo.size.height - 84 - 14))
                    .frame(width: Self.panelWidth)
            }
            .padding(.top, 84)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(12)
        .task(id: model.modules.count) { await model.prepareSimple() }
    }
}

struct SimplePanel: View {
    @Bindable var model: DarkroomModel
    /// The height the panel may take; past it the controls scroll.
    var maxHeight: CGFloat = .infinity
    /// Looks are an occasional starting point, not a constant control: folded away unless opened, and
    /// the choice is remembered.
    @AppStorage(SimplePanel.looksOpenKey) private var looksOpen = false
    static let looksOpenKey = "darkroom.simple.looksOpen"

    var body: some View {
        ViewThatFits(in: .vertical) {
            controls
            ScrollView(.vertical) { controls }.scrollIndicators(.visible)
        }
        .frame(maxHeight: maxHeight)
        .padding(14)
        .disabled(!model.simpleReady)
        .opacity(model.simpleReady ? 1 : 0.5)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var controls: some View {
        VStack(spacing: 4) {
            Button { withAnimation(.snappy) { looksOpen.toggle() } } label: {
                HStack {
                    Text("Looks").font(.callout.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(looksOpen ? 0 : -90))
                }
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(looksOpen ? "Hide looks" : "Show looks")
            .rig("simple-looks")
            if looksOpen {
                LooksRow(model: model)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Divider().padding(.bottom, 4)

            ForEach(model.simpleControls) { c in
                VStack(spacing: 0) {
                    HStack {
                        Text(c.rawValue).font(.callout.weight(.medium))
                        if model.simpleTouchedByPro(c) {
                            Circle().fill(Theme.accent).frame(width: 7, height: 7)
                                .accessibilityLabel("Also edited in Pro")
                        }
                        Spacer()
                        Text(String(format: "%+.0f", model.simpleValue(c)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { model.simpleValue(c) }, set: { model.setSimple(c, to: $0) }),
                           in: c.range, step: 1, onEditingChanged: { model.setDragging($0) })
                        .tint(Theme.accent)
                        .frame(height: 36)
                        .accessibilityLabel(c.rawValue)
                        .rig("simple-\(c.rawValue.lowercased())")
                        .onAppear {
                            if Rig.enabled {
                                Rig.setters["simple-\(c.rawValue.lowercased())"] = { frac in
                                    model.setSimple(c, to: c.range.lowerBound + (c.range.upperBound - c.range.lowerBound) * frac)
                                }
                            }
                        }
                }
            }

            Divider().padding(.vertical, 6)

            VStack(spacing: 6) {
                HStack {
                    Text("Straighten").font(.callout.weight(.medium))
                    Spacer()
                    Text(String(format: "%+.1f°", model.simpleStraighten))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { model.simpleStraighten }, set: { model.setStraighten($0) }),
                       in: DarkroomModel.straightenRange, step: 0.1, onEditingChanged: { model.setDragging($0) })
                    .tint(Theme.accent)
                    .frame(height: 36)
                    .accessibilityLabel("Straighten")
                    .rig("simple-straighten")
                    .onAppear {
                        if Rig.enabled {
                            Rig.setters["simple-straighten"] = { frac in
                                let r = DarkroomModel.straightenRange
                                model.setStraighten(r.lowerBound + (r.upperBound - r.lowerBound) * frac)
                            }
                        }
                    }

                AutoWhiteBalanceButton(model: model, id: "simple-awb")

                Button { model.rotate90() } label: {
                    Label("Rotate 90°", systemImage: "rotate.right")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .rig("simple-rotate")
                .accessibilityLabel("Rotate 90 degrees clockwise")

                HStack(spacing: 6) {
                    ForEach(SimpleAspect.allCases) { a in
                        Button { model.setAspect(a) } label: {
                            Text(a.rawValue)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(Color.white.opacity(model.simpleAspect == a ? 0.26 : 0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .rig("simple-aspect-\(a.slug)")
                        .accessibilityLabel(a.spoken)
                        .accessibilityAddTraits(model.simpleAspect == a ? .isSelected : [])
                    }
                }
            }
            .disabled(!model.simpleGeometryReady)
            .opacity(model.simpleGeometryReady ? 1 : 0.5)

            if model.customEditCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Custom edits, \(model.customEditCount)").font(.callout.weight(.semibold))
                        Spacer()
                        Text("from Pro").font(.caption2.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    Text("Simple keeps them. Switch to Pro to see or change them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                .padding(.top, 4)
            }

            Button { model.mode = .pro } label: {
                HStack {
                    Text("More controls").foregroundStyle(.secondary)
                    Spacer()
                    Text("Switch to Pro").foregroundStyle(Theme.accent)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rig("simple-more")
        }
    }
}

/// The six looks as one row at the top of the Simple panel (Auto first). A look is five slider
/// positions, so tapping one is the same as dragging the five sliders.
struct LooksRow: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SimpleLook.all) { look in
                Button { model.apply(look) } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(colors: look.swatch, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 40, height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                        Text(look.name)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(look.name) look")
                .rig("look-\(look.id)")
            }
        }
    }
}

/// The Simple | Pro switch that sits in the header.
struct ModeSwitch: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditMode.allCases, id: \.self) { m in
                Button { model.mode = m } label: {
                    Text(m.rawValue)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(model.mode == m ? Color.white.opacity(0.26) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .rig("mode-\(m.rawValue.lowercased())")
                .accessibilityAddTraits(model.mode == m ? .isSelected : [])
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .capsule)
    }
}


/// "Auto white balance": measures the photo and writes the white balance module's gains as one undo step.
struct AutoWhiteBalanceButton: View {
    @Bindable var model: DarkroomModel
    let id: String

    var body: some View {
        Button { Task { await model.autoWhiteBalance() } } label: {
            Label("Auto white balance", systemImage: "wand.and.stars")
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .rig(id)
        .accessibilityLabel("Auto white balance")
    }
}
