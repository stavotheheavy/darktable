import DarkroomEngineAPI
import SwiftUI

/// What sits behind the photo. Not black by default: a smooth deep blue-black with a soft
/// falloff gives the photo depth without competing with it. Anyone can pick their own
/// colour, texture and vignette; the felt grain is there but off unless chosen.
public struct BackdropStyle: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var red: Double
    public var green: Double
    public var blue: Double
    /// 0...1: how strong the felt grain is.
    public var felt: Double
    /// 0...1: how much the edges fall off toward black.
    public var vignette: Double

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    public init(name: String, red: Double, green: Double, blue: Double, felt: Double, vignette: Double) {
        self.name = name
        self.red = red; self.green = green; self.blue = blue
        self.felt = felt; self.vignette = vignette
    }

    /// The default: smooth, deep blue-black with a soft falloff at the edges. No grain.
    public static let night = BackdropStyle(
        name: "Night", red: 0.075, green: 0.082, blue: 0.108, felt: 0, vignette: 0.35)
    public static let depthGrey = BackdropStyle(
        name: "Depth grey", red: 0.24, green: 0.24, blue: 0.255, felt: 0, vignette: 0.55)
    public static let charcoal = BackdropStyle(
        name: "Charcoal", red: 0.13, green: 0.13, blue: 0.14, felt: 0, vignette: 0.3)
    public static let neutralGrey = BackdropStyle(
        name: "Neutral grey", red: 0.46, green: 0.46, blue: 0.46, felt: 0, vignette: 0)
    public static let lightGrey = BackdropStyle(
        name: "Light grey", red: 0.74, green: 0.74, blue: 0.74, felt: 0, vignette: 0)
    public static let black = BackdropStyle(
        name: "Black", red: 0, green: 0, blue: 0, felt: 0, vignette: 0)

    public static let presets: [BackdropStyle] = [.night, .depthGrey, .charcoal, .neutralGrey, .lightGrey, .black]

    /// A custom colour keeps the texture and vignette the user already chose.
    public func with(color: Color) -> BackdropStyle {
        let c = Platform.rgb(of: color)
        var s = self
        s.name = "Custom"
        s.red = c.red; s.green = c.green; s.blue = c.blue
        return s
    }

    // MARK: persistence

    // v2: the first default was a grey felt with visible grain, which the owner did not like
    static let key = "darkroom.backdrop.v2"

    static func load() -> BackdropStyle {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(BackdropStyle.self, from: data) else { return .night }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// The board itself: base colour, felt grain, and a vignette.
struct BackdropView: View {
    let style: BackdropStyle

    var body: some View {
        ZStack {
            style.color
            if style.felt > 0.01 {
                Image(decorative: FeltTile.image, scale: 1)
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(style.felt)
            }
            if style.vignette > 0.01 {
                RadialGradient(
                    colors: [.clear, .black.opacity(style.vignette * 0.6)],
                    center: .center, startRadius: 120, endRadius: 900)
                    .blendMode(.multiply)
            }
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

/// A small tile of fine grey noise, made once; tiled at low opacity it reads as felt.
enum FeltTile {
    static let image: CGImage = {
        let n = 128
        var px = [UInt8](repeating: 255, count: n * n * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
        for i in 0..<(n * n) {
            // two samples averaged: finer, softer grain than raw white noise
            let v = UInt8((Int(next()) + Int(next())) / 2)
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
        }
        let space = CGColorSpaceCreateDeviceRGB()
        return px.withUnsafeMutableBytes { raw -> CGImage in
            let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                bytesPerRow: n * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
    }()
}

/// The control for it: presets, and a custom colour with its own texture and vignette.
struct BackdropMenu: View {
    @Bindable var model: DarkroomModel
    @State private var custom = false

    var body: some View {
        Menu {
            ForEach(BackdropStyle.presets) { p in
                Button {
                    model.backdrop = p
                } label: {
                    if model.backdrop.name == p.name { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            Divider()
            Button("Custom…") { custom = true }
        } label: {
            Image(systemName: "paintpalette").frame(width: 40, height: 40)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Background")
        .accessibilityIdentifier("backdrop")
        .popover(isPresented: $custom, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Background").font(.headline)
                ColorPicker("Colour", selection: Binding(
                    get: { model.backdrop.color },
                    set: { model.backdrop = model.backdrop.with(color: $0) }))
                    .accessibilityIdentifier("backdrop-colour")
                LabeledContent("Felt") {
                    Slider(value: Binding(get: { model.backdrop.felt },
                                          set: { var b = model.backdrop; b.felt = $0; b.name = "Custom"; model.backdrop = b }),
                           in: 0...1)
                        .frame(width: 160)
                        .accessibilityIdentifier("backdrop-felt")
                }
                LabeledContent("Vignette") {
                    Slider(value: Binding(get: { model.backdrop.vignette },
                                          set: { var b = model.backdrop; b.vignette = $0; b.name = "Custom"; model.backdrop = b }),
                           in: 0...1)
                        .frame(width: 160)
                        .accessibilityIdentifier("backdrop-vignette")
                }
            }
            .padding(16)
            .frame(width: 300)
        }
    }
}
