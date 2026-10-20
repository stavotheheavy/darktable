// Method: a product table, no algorithm: the controls the app shows for each local-mask kind, with the blend keys the
// engine reads (DarkroomCore.Mask and its kinds), their ranges and defaults. darkroom-engine-check MS1 holds it to the
// engine: every key here must change the parsed mask, and the defaults here must be the engine's own.

import Foundation

public struct MaskControl: Sendable, Equatable {
    public let key: String
    public let label: String
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    /// Shown after the value: "°", " px", "".
    public let unit: String
    /// Decimals in the value readout.
    public let decimals: Int
}

public enum MaskKind: Int, CaseIterable, Sendable {
    case gradient = 1, ellipse = 2, brightness = 3, colour = 4

    /// What the picker says.
    public var title: String {
        switch self {
        case .gradient: "gradient"
        case .ellipse: "ellipse"
        case .brightness: "brightness"
        case .colour: "colour"
        }
    }

    public var controls: [MaskControl] {
        func c(_ key: String, _ label: String, _ range: ClosedRange<Double>, _ d: Double, _ unit: String = "", _ decimals: Int = 2) -> MaskControl {
            MaskControl(key: key, label: label, range: range, defaultValue: d, unit: unit, decimals: decimals)
        }
        switch self {
        case .gradient:
            return [c("mask_angle", "angle", 0...360, 0, "\u{00B0}", 0), c("mask_position", "position", 0...1, 0.5),
                    c("mask_feather", "feather", 0...1, 0.2)]
        case .ellipse:
            return [c("mask_cx", "centre x", 0...1, 0.5), c("mask_cy", "centre y", 0...1, 0.5),
                    c("mask_rx", "width", 0.01...1, 0.25), c("mask_ry", "height", 0.01...1, 0.25),
                    c("mask_rotation", "rotation", -90...90, 0, "\u{00B0}", 0), c("mask_feather", "feather", 0...1, 0.2)]
        case .brightness:
            return [c("mask_low", "from", 0...2, 0.2), c("mask_high", "to", 0...2, 0.8), c("mask_feather", "feather", 0...1, 0.25)]
        case .colour:
            return [c("mask_hue", "hue", 0...360, 30, "\u{00B0}", 0), c("mask_hue_width", "range", 1...180, 30, "\u{00B0}", 0),
                    c("mask_chroma_min", "min colour", 0...0.3, 0.02, "", 3), c("mask_feather", "feather", 0...1, 0.3)]
        }
    }
}

/// The controls every kind shares.
public enum MaskCommon {
    public static let refine = MaskControl(key: "mask_refine", label: "edge refine", range: 0...50, defaultValue: 0, unit: " px", decimals: 0)
}
