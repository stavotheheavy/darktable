import DarktableKit
import Foundation

/// What the user changed on one module instance, on top of the imported state.
/// Only fields the user touched are stored; everything else stays as darktable has it.
public struct ModuleEdit: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var params: [String: ParamValue] = [:]
    public var blend: [String: ParamValue] = [:]
    /// Pro mode's panel: true when added from the Modules menu, false when taken out, nil when the module
    /// shows by default (a basic, applied, or edited). Kept with the edit so undo, redo and the sidecar carry it.
    public var inPanel: Bool?

    /// A change to the picture (on/off, parameters, blend); panel membership alone is not one.
    public var changesPicture: Bool { enabled != nil || !params.isEmpty || !blend.isEmpty }
    public var isEmpty: Bool { !changesPicture && inPanel == nil }
}

public typealias EditMap = [String: ModuleEdit]   // key: ModuleInfo.id

/// One step in the edit history: a full snapshot, so jumping to any step is exact.
public struct HistoryItem: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var label: String
    public var detail: String
    public var edits: EditMap
    /// What changed, so repeated drags of the same control merge into one step.
    var target: String?
    var time: Date = Date()
}

/// The saved form of an image's edits, kept next to the raw like an XMP sidecar.
struct Sidecar: Codable {
    var version = 1
    var history: [HistoryItem]
    var index: Int

    static func url(for rawPath: String) -> URL {
        URL(fileURLWithPath: rawPath + ".darkroom.json")
    }

    static func load(for rawPath: String) -> Sidecar? {
        guard
            let data = try? Data(contentsOf: url(for: rawPath)),
            let s = try? JSONDecoder().decode(Sidecar.self, from: data),
            s.version == 1, !s.history.isEmpty
        else { return nil }
        return s
    }

    func save(for rawPath: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url(for: rawPath), options: .atomic)
    }
}

/// Soft slider ranges for fields whose declared hard range is too wide to be a good
/// slider (exposure allows +/-18 EV). The hard range still bounds typed values.
enum SoftRange {
    static let table: [String: ClosedRange<Double>] = [
        "exposure.exposure": -4...4,
        "exposure.black": -0.1...0.1,
        "shadhi.radius": 0...100,
        "sharpen.radius": 0...10,
        "bilat.sigma_r": 0...100,
        "bilat.sigma_s": 0...100,
        "temperature.red": 0.3...3,
        "temperature.green": 0.3...3,
        "temperature.blue": 0.3...3,
    ]

    static func range(operation: String, field: FieldSchema) -> ClosedRange<Double>? {
        if let r = table["\(operation).\(field.name)"] { return r }
        guard field.hasUsableRange, field.max > field.min else { return nil }
        return field.min...field.max
    }
}
