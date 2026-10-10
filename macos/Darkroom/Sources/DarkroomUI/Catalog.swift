import Foundation

/// The tools the capsule offers. Only tools whose sliders map to real darktable
/// module fields are listed; the rest are added when they are wired for real.
public enum Tool: String, CaseIterable, Identifiable, Sendable {
    case light
    case detail

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: "Light"
        case .detail: "Detail"
        }
    }

    public var symbol: String {
        switch self {
        case .light: "sun.max"
        case .detail: "square.grid.2x2"
        }
    }

    public var sliders: [SliderSpec] { Catalog.all.filter { $0.tool == self } }
}

/// One friendly slider and the darktable module field it drives.
public struct SliderSpec: Identifiable, Sendable {
    public let id: String
    public let tool: Tool
    public let label: String
    public let module: String      // darktable operation name
    public let field: String       // parameter field in that module's introspection
    public let range: ClosedRange<Double>
    /// Value that leaves the picture as if the slider were untouched. Used for the
    /// fields of a module the user has touched but whose own slider they have not.
    public let neutral: Double
    public let display: @Sendable (Double) -> String
}

public enum Catalog {
    // Fields read from src/iop/{exposure,shadhi,colorbalancergb,sharpen}.c
    public static let all: [SliderSpec] = [
        SliderSpec(id: "exposure", tool: .light, label: "Exposure", module: "exposure", field: "exposure",
                   range: -3...3, neutral: 0, display: { String(format: "%+.2f EV", $0) }),
        SliderSpec(id: "contrast", tool: .light, label: "Contrast", module: "colorbalancergb", field: "contrast",
                   range: -1...1, neutral: 0, display: { String(format: "%+.0f", $0 * 100) }),
        SliderSpec(id: "highlights", tool: .light, label: "Highlights", module: "shadhi", field: "highlights",
                   range: -100...100, neutral: 0, display: { String(format: "%+.0f", $0) }),
        SliderSpec(id: "shadows", tool: .light, label: "Shadows", module: "shadhi", field: "shadows",
                   range: -100...100, neutral: 0, display: { String(format: "%+.0f", $0) }),
        SliderSpec(id: "whitepoint", tool: .light, label: "White point", module: "shadhi", field: "whitepoint",
                   range: -10...10, neutral: 0, display: { String(format: "%+.1f", $0) }),
        SliderSpec(id: "blacks", tool: .light, label: "Black level", module: "exposure", field: "black",
                   range: -0.1...0.1, neutral: 0, display: { String(format: "%+.3f", $0) }),

        SliderSpec(id: "sharpen", tool: .detail, label: "Sharpen", module: "sharpen", field: "amount",
                   range: 0...2, neutral: 0, display: { String(format: "%.0f", $0 * 50) }),
        SliderSpec(id: "radius", tool: .detail, label: "Radius", module: "sharpen", field: "radius",
                   range: 0.5...10, neutral: 2, display: { String(format: "%.1f px", $0) }),
    ]

    public static func spec(_ id: String) -> SliderSpec? { all.first { $0.id == id } }
}
