import DarkroomCore
import DarktableKit
import Foundation

/// Simple mode's crop presets: long side over short side, turned to match the picture (a portrait photo
/// gets a portrait 4:5). Original is no crop.
public enum SimpleAspect: String, CaseIterable, Identifiable, Sendable {
    case original = "Original", square = "1:1", fourFive = "4:5", threeTwo = "3:2", sixteenNine = "16:9"
    public var id: String { rawValue }

    /// URL-safe, for rig ids (the rig is an HTTP server, so no colons): original, 1x1, 4x5, 3x2, 16x9.
    public var slug: String { self == .original ? "original" : rawValue.replacingOccurrences(of: ":", with: "x") }

    /// What VoiceOver says, instead of reading "1:1" literally.
    public var spoken: String {
        switch self {
        case .original: "Original, no crop"
        case .square: "Square crop"
        case .fourFive: "4 by 5 crop"
        case .threeTwo: "3 by 2 crop"
        case .sixteenNine: "16 by 9 crop"
        }
    }

    var longOverShort: Double? {
        switch self {
        case .original: nil
        case .square: 1
        case .fourFive: 1.25
        case .threeTwo: 1.5
        case .sixteenNine: 16.0 / 9
        }
    }
}

// MARK: straighten, rotate, aspect

/// Simple's geometry writes the real flip, ashift and crop parameters, one history step per control, so
/// Pro shows every value. The maths is DarkroomCore's geometry oracle, the same the engine renders with:
/// straighten's crop is computed in sensor orientation, the aspect crop on the frame straighten and flip leave.
extension DarkroomModel {
    static let simpleGeometryOperations = ["flip", "ashift", "crop"]
    static let straightenRange: ClosedRange<Double> = -45...45

    /// The controls need the engine's sensor size and the camera's orientation (the clean engine reports
    /// both; the darktable engine does not yet), and the three modules' schemas.
    public var simpleGeometryReady: Bool {
        geometryBase != nil && Self.simpleGeometryOperations.allSatisfy { module($0) != nil && schemas[$0] != nil }
    }

    /// Straighten in degrees, read back from ashift's rotation (positive turns the picture anticlockwise).
    public var simpleStraighten: Double {
        guard let m = module("ashift"), isEnabled(m) else { return 0 }
        return geometryNumber("ashift", "rotation") ?? 0
    }

    /// The orientation the picture has now: the stack's flip when it sets one, else the camera's.
    var currentOrientation: Orientation {
        guard let base = geometryBase else { return .none }
        guard let m = module("flip"), isEnabled(m), let (_, f) = field("flip", "orientation") else { return base.camera }
        switch value(m, f) {
        case .option(let name) where name != "ORIENTATION_NULL": return Orientation(name: name)
        case .number(let v) where v >= 0: return Orientation(value: Int(v))
        default: return base.camera
        }
    }

    /// The preset the current crop is, if it is one: centred, with a preset's aspect within 1%. Nil for
    /// a crop made in Pro that is none of them.
    public var simpleAspect: SimpleAspect? {
        guard let m = module("crop"), isEnabled(m) else { return .original }
        let rect = CropRect(left: geometryNumber("crop", "cx") ?? 0, top: geometryNumber("crop", "cy") ?? 0,
                            right: geometryNumber("crop", "cw") ?? 1, bottom: geometryNumber("crop", "ch") ?? 1)
        if rect == .full { return .original }
        guard let pre = preCropSize(degrees: simpleStraighten, orientation: currentOrientation) else { return nil }
        let centred = abs(rect.left - (1 - rect.right)) < 0.002 && abs(rect.top - (1 - rect.bottom)) < 0.002
        let w = (rect.right - rect.left) * pre.x, h = (rect.bottom - rect.top) * pre.y
        guard centred, w > 0, h > 0 else { return nil }
        let ratio = max(w, h) / min(w, h)
        return SimpleAspect.allCases.first { a in a.longOverShort.map { abs($0 - ratio) / $0 < 0.01 } ?? false }
    }

    /// Straightens by `degrees` (clamped to -45...45, 0.1-degree steps), cropping to the largest clean
    /// rectangle; an aspect preset in use is kept. One history step.
    public func setStraighten(_ degrees: Double) {
        let d = (min(max(degrees, Self.straightenRange.lowerBound), Self.straightenRange.upperBound) * 10).rounded() / 10
        let aspect = simpleAspect
        let orientation = currentOrientation
        grouped("Straighten", target: "simple.straighten") {
            writeStraighten(d)
            if let a = aspect, a != .original { writeAspect(a, degrees: d, orientation: orientation) }
        }
    }

    /// Turns the picture 90 degrees clockwise; an aspect preset in use turns with it. One history step.
    public func rotate90() { turn(.rotateCW90, label: "Rotate") }

    /// A quarter turn either way, or a mirror: `then` composes it with what the picture has now. One history step each press.
    public func turn(_ t: Orientation, label: String) {
        let aspect = simpleAspect
        let next = currentOrientation.then(t)
        let degrees = simpleStraighten
        // a button: every tap is its own step, unlike a slider's drag (`grouped` merges a repeated target)
        grouped(label, target: "simple.rotate.\(history.count)") {
            writeGeometry("flip", "orientation", .option(next.name))
            if let a = aspect, a != .original { writeAspect(a, degrees: degrees, orientation: next) }
        }
    }

    /// Crops to a centred `aspect` (Original removes the crop). One history step.
    public func setAspect(_ aspect: SimpleAspect) {
        let degrees = simpleStraighten, orientation = currentOrientation
        grouped("Aspect \(aspect.rawValue)", target: "simple.aspect.\(history.count)") {
            writeAspect(aspect, degrees: degrees, orientation: orientation)
        }
    }

    /// Crop, straighten, turn and flip all back to nothing, as one history step.
    public func resetGeometry() {
        let ms = Self.simpleGeometryOperations.compactMap { module($0) }
        guard ms.contains(where: isEdited) else { return }
        grouped("Reset crop and straighten", target: "crop.reset.\(history.count)") { ms.forEach(resetModule) }
    }
    public var geometryEdited: Bool { Self.simpleGeometryOperations.compactMap { module($0) }.contains(where: isEdited) }

    // MARK: helpers

    /// The frame straighten and flip leave for these settings, before the crop, at scale 1.
    func preCropSize(degrees: Double, orientation: Orientation) -> SIMD2<Double>? {
        guard let base = geometryBase else { return nil }
        let keep = Straighten.cropFractions(base.sensor, degrees: degrees, mode: .largest)
        return GeometrySpec(orientation: orientation, degrees: degrees, straightenCrop: keep).outputSize(base.sensor)
    }

    private func writeStraighten(_ degrees: Double) {
        guard let base = geometryBase else { return }
        let keep = Straighten.cropFractions(base.sensor, degrees: degrees, mode: .largest)
        writeGeometry("ashift", "rotation", .number(degrees))
        writeGeometry("ashift", "cl", .number(keep.left))
        writeGeometry("ashift", "cr", .number(keep.right))
        writeGeometry("ashift", "ct", .number(keep.top))
        writeGeometry("ashift", "cb", .number(keep.bottom))
    }

    private func writeAspect(_ aspect: SimpleAspect, degrees: Double, orientation: Orientation) {
        guard let pre = preCropSize(degrees: degrees, orientation: orientation) else { return }
        let rect = aspect.longOverShort.map { CropRect.centred(longOverShort: $0, in: pre) } ?? .full
        writeGeometry("crop", "cx", .number(rect.left))
        writeGeometry("crop", "cy", .number(rect.top))
        writeGeometry("crop", "cw", .number(rect.right))
        writeGeometry("crop", "ch", .number(rect.bottom))
    }

    private func geometryNumber(_ operation: String, _ name: String) -> Double? {
        guard let (m, f) = field(operation, name) else { return nil }
        return value(m, f).double
    }

    private func writeGeometry(_ operation: String, _ name: String, _ v: ParamValue) {
        guard let (m, f) = field(operation, name) else { return }
        setParam(m, f, to: v)
    }
}
