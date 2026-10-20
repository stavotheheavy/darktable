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
///
/// Version 3 adds `layers` (painted and detected masks); a file with none stays version 2, so an app that predates layers
/// still reads it, and a file with layers is left alone by that app (it cannot read them and would drop them).
///
/// Version 2 adds `algorithms`: the algorithm version of every module the history uses, as the engine that saved it
/// reported (roadmap T11). Version 1 files (no `algorithms`) still load. A file with a version this app does not know
/// is never read and never overwritten: its edits belong to a newer app.
struct Sidecar: Codable {
    static let currentVersion = 3

    var version = 2
    var history: [HistoryItem]
    var index: Int
    var algorithms: [String: Int]?
    var layers: [MaskLayer]?

    enum Loaded {
        case none
        case loaded(Sidecar)
        /// A sidecar this app cannot read (a newer format, or damaged): left on disk untouched.
        case unreadable(String)
    }

    static func url(for rawPath: String) -> URL {
        URL(fileURLWithPath: rawPath + ".darkroom.json")
    }

    static func read(for rawPath: String) -> Loaded {
        guard let data = try? Data(contentsOf: url(for: rawPath)) else { return .none }
        struct Header: Decodable { var version: Int? }
        guard let version = (try? JSONDecoder().decode(Header.self, from: data))?.version else {
            return .unreadable("its sidecar is not a Vantage file")
        }
        guard (1...currentVersion).contains(version) else {
            return .unreadable("its edits were saved by a newer Vantage (sidecar format \(version))")
        }
        guard let s = try? JSONDecoder().decode(Sidecar.self, from: data), !s.history.isEmpty else {
            return .unreadable("its sidecar is damaged")
        }
        return .loaded(s)
    }

    static func load(for rawPath: String) -> Sidecar? {
        if case .loaded(let s) = read(for: rawPath) { return s }
        return nil
    }

    func save(for rawPath: String) throws {
        var s = self
        if s.layers?.isEmpty == true { s.layers = nil }
        s.version = s.layers == nil ? 2 : 3
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: Self.url(for: rawPath), options: .atomic)
    }

    /// What differs between the maths that made these edits and this app's, one sentence per module the history uses.
    /// A module saved at a higher version than this app knows is "newer"; at a lower one, "changed since".
    func versionNotices(current: [String: Int]) -> [String] {
        guard let saved = algorithms, !current.isEmpty else { return [] }
        let used = Set(history[min(max(0, index), history.count - 1)].edits.filter { $0.value.changesPicture }.keys
            .map { String($0.split(separator: "#").first ?? "") })
        return used.sorted().compactMap { op in
            guard let was = saved[op], let now = current[op], was != now else { return nil }
            return was > now
                ? "\(op): edited with a newer algorithm (version \(was); this app has \(now)), so it may look different"
                : "\(op): the algorithm changed since you edited (version \(was), now \(now)), so it may look different"
        }
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
