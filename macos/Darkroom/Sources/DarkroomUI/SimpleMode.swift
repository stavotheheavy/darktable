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
    case light = "Light", contrast = "Contrast", color = "Color", warmth = "Warmth", detail = "Detail"
    public var id: String { rawValue }
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

    func module(_ operation: String) -> ModuleInfo? { modules.first { $0.operation == operation } }

    func field(_ operation: String, _ name: String) -> (ModuleInfo, FieldSchema)? {
        guard let m = module(operation), let f = schemas[operation]?.fields.first(where: { $0.name == name })
        else { return nil }
        return (m, f)
    }

    /// Schemas arrive lazily; Simple needs a handful of them before its sliders mean anything.
    public func prepareSimple() async {
        for op in Self.simpleOperations { if let m = module(op) { await loadSchema(for: m) } }
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

    private func writeSimple(_ c: SimpleControl, to v: Double) {
        let v = min(max(v, c.range.lowerBound), c.range.upperBound)
        switch c {
        case .light:
            write("exposure", "exposure", v / 100 * 2)
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
        case .contrast, .color: ("colorbalancergb", ["contrast", "vibrance", "saturation_global"])
        case .warmth: ("temperature", ["red", "blue"])
        case .detail: ("sharpen", ["amount"])
        }
        guard let m = module(op), let e = edits[m.id] else { return false }
        return !Set(e.params.keys).subtracting(owned).isEmpty || !e.blend.isEmpty
    }

    /// Edited modules Simple has no slider for, so the panel can say what Pro changed.
    public var customEditCount: Int {
        moduleRows.filter { $0.edited && !Self.simpleOperations.contains($0.module.operation) }.count
    }
}

// MARK: views

struct SimpleChrome: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        ZStack {
            HStack(alignment: .top) {
                Spacer(minLength: 0)
                SimplePanel(model: model).frame(width: 316)
            }
            .padding(.top, 84)
            .frame(maxHeight: .infinity, alignment: .top)
            VStack {
                Spacer()
                LooksStrip(model: model).padding(.bottom, 14)
            }
        }
        .padding(12)
        .task(id: model.modules.count) { await model.prepareSimple() }
    }
}

struct SimplePanel: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button { if let a = SimpleLook.all.first { model.apply(a) } } label: {
                    Label("Auto", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryCapsuleStyle())
                .rig("simple-auto")
            }
            .padding(.bottom, 2)

            ForEach(SimpleControl.allCases) { c in
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
                           in: c.range, step: 1)
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
        .padding(14)
        .disabled(!model.simpleReady)
        .opacity(model.simpleReady ? 1 : 0.5)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

struct LooksStrip: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SimpleLook.all) { look in
                Button { model.apply(look) } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(LinearGradient(colors: look.swatch, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 52, height: 52)
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                        Text(look.name).font(.caption.weight(.medium))
                    }
                    .frame(width: 88, height: 84)
                }
                .buttonStyle(.plain)
                .disabled(!model.simpleReady)
                .rig("look-\(look.id)")
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 36))
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
