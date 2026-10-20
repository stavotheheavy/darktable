import Foundation

/// A parameter value as darktable's introspection sees it.
public enum ParamValue: Sendable, Hashable, Codable {
    case number(Double)
    case bool(Bool)
    case option(String)   // an enum member by its symbolic name

    public var double: Double? {
        switch self {
        case .number(let d): d
        case .bool(let b): b ? 1 : 0
        case .option: nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let d): d != 0
        case .option: nil
        }
    }

    public var option: String? {
        if case .option(let s) = self { s } else { nil }
    }

    /// What goes into a stack entry's JSON.
    public var jsonObject: Any {
        switch self {
        case .number(let d): d
        case .bool(let b): b
        case .option(let s): s
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else { self = .option(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .option(let s): try c.encode(s)
        }
    }

    static func from(json: Any?) -> ParamValue? {
        switch json {
        case let n as NSNumber:
            // JSONSerialization hands booleans back as NSNumber too
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String:
            return .option(s)
        default:
            return nil
        }
    }
}

extension ParamValue: ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral,
                      ExpressibleByBooleanLiteral, ExpressibleByStringLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(stringLiteral value: String) { self = .option(value) }
}

/// The blend parameters a stack entry can set, as the module list reports them.
public struct BlendInfo: Sendable, Equatable {
    public var maskMode: Int
    public var blendMode: Int
    public var reverse: Bool
    public var opacity: Double
    public var blendParameter: Double
    public var maskCombine: Int
    public var featheringRadius: Double
    public var blurRadius: Double
    public var contrast: Double
    public var brightness: Double

    /// A module's blending at its defaults: uniform off, normal mode, full opacity.
    public init(maskMode: Int = 0, blendMode: Int = 0x18, reverse: Bool = false, opacity: Double = 100, blendParameter: Double = 0,
                maskCombine: Int = 0, featheringRadius: Double = 0, blurRadius: Double = 0, contrast: Double = 0, brightness: Double = 0) {
        self.maskMode = maskMode; self.blendMode = blendMode; self.reverse = reverse; self.opacity = opacity
        self.blendParameter = blendParameter; self.maskCombine = maskCombine; self.featheringRadius = featheringRadius
        self.blurRadius = blurRadius; self.contrast = contrast; self.brightness = brightness
    }

    static func from(json o: [String: Any]) -> BlendInfo {
        func d(_ k: String) -> Double { (o[k] as? NSNumber)?.doubleValue ?? 0 }
        func i(_ k: String) -> Int { (o[k] as? NSNumber)?.intValue ?? 0 }
        return BlendInfo(
            maskMode: i("mask_mode"), blendMode: i("blend_mode"),
            reverse: (o["reverse"] as? NSNumber)?.boolValue ?? false,
            opacity: d("opacity"), blendParameter: d("blend_parameter"), maskCombine: i("mask_combine"),
            featheringRadius: d("feathering_radius"), blurRadius: d("blur_radius"),
            contrast: d("contrast"), brightness: d("brightness"))
    }
}

/// One module instance in the pipeline, in the imported state.
public struct ModuleInfo: Sendable, Identifiable, Equatable {
    public var id: String { "\(operation)#\(multiPriority)" }

    public let operation: String
    public let multiPriority: Int
    public let multiName: String
    /// True only for a name the user typed; presets label instances too, e.g. `_builtin_scene-referred default`.
    public let multiNameHandEdited: Bool
    public let name: String
    public let iopOrder: Int
    public let enabled: Bool
    public let defaultEnabled: Bool
    public let hideEnableButton: Bool
    public let deprecated: Bool
    public let oneInstance: Bool
    public let supportsBlending: Bool
    public let noMasks: Bool
    public let group: Int
    public let haveIntrospection: Bool
    public let params: [String: ParamValue]
    public let blend: BlendInfo?

    public init(operation: String, multiPriority: Int = 0, multiName: String = "",
                multiNameHandEdited: Bool = false, name: String, iopOrder: Int,
                enabled: Bool, defaultEnabled: Bool, hideEnableButton: Bool = false,
                deprecated: Bool = false, oneInstance: Bool = true, supportsBlending: Bool = false,
                noMasks: Bool = true, group: Int = 0, haveIntrospection: Bool = true,
                params: [String: ParamValue], blend: BlendInfo? = nil) {
        self.operation = operation
        self.multiPriority = multiPriority
        self.multiName = multiName
        self.multiNameHandEdited = multiNameHandEdited
        self.name = name
        self.iopOrder = iopOrder
        self.enabled = enabled
        self.defaultEnabled = defaultEnabled
        self.hideEnableButton = hideEnableButton
        self.deprecated = deprecated
        self.oneInstance = oneInstance
        self.supportsBlending = supportsBlending
        self.noMasks = noMasks
        self.group = group
        self.haveIntrospection = haveIntrospection
        self.params = params
        self.blend = blend
    }

    /// "exposure", or "color balance rgb · skin" when the user named the instance.
    public var title: String {
        multiNameHandEdited && !multiName.isEmpty ? "\(name) · \(multiName)" : name
    }

    public static func parse(_ data: Data) throws -> [ModuleInfo] {
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw EngineError("module list is not an array")
        }
        return arr.compactMap { o in
            guard let op = o["operation"] as? String else { return nil }
            func b(_ k: String) -> Bool { (o[k] as? NSNumber)?.boolValue ?? false }
            var params: [String: ParamValue] = [:]
            if let p = o["params"] as? [String: Any] {
                for (k, v) in p { if let pv = ParamValue.from(json: v) { params[k] = pv } }
            }
            return ModuleInfo(
                operation: op,
                multiPriority: (o["multi_priority"] as? NSNumber)?.intValue ?? 0,
                multiName: o["multi_name"] as? String ?? "",
                multiNameHandEdited: b("multi_name_hand_edited"),
                name: o["name"] as? String ?? op,
                iopOrder: (o["iop_order"] as? NSNumber)?.intValue ?? 0,
                enabled: b("enabled"), defaultEnabled: b("default_enabled"),
                hideEnableButton: b("hide_enable_button"), deprecated: b("deprecated"),
                oneInstance: b("one_instance"), supportsBlending: b("supports_blending"),
                noMasks: b("no_masks"),
                group: (o["group"] as? NSNumber)?.intValue ?? 0,
                haveIntrospection: b("have_introspection"),
                params: params,
                blend: (o["blend"] as? [String: Any]).map(BlendInfo.from(json:)))
        }
    }
}

public struct EnumOption: Sendable, Hashable {
    public let name: String   // the symbolic name, e.g. EXPOSURE_MODE_MANUAL
    public let value: Int
    /// "manual" for EXPOSURE_MODE_MANUAL: the shared prefix dropped, lower case.
    public let label: String

    public init(name: String, value: Int, label: String) {
        self.name = name
        self.value = value
        self.label = label
    }
}

public struct FieldSchema: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case float, int, bool, enumeration }

    public var id: String { name }
    public let name: String
    public let description: String
    public let kind: Kind
    public let min: Double
    public let max: Double
    public let defaultValue: ParamValue
    public let options: [EnumOption]

    public init(name: String, description: String, kind: Kind, min: Double, max: Double,
                defaultValue: ParamValue, options: [EnumOption]) {
        self.name = name
        self.description = description
        self.kind = kind
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
        self.options = options
    }

    /// A label a person would read: darktable's own description, else the field name.
    public var label: String {
        if !description.isEmpty { return description }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    /// Whether min and max are real declared limits rather than the type's full range.
    public var hasUsableRange: Bool {
        kind == .float || kind == .int ? (max - min) < 1e6 : false
    }
}

public struct ModuleSchema: Sendable {
    public let operation: String
    public let fields: [FieldSchema]

    public init(operation: String, fields: [FieldSchema]) {
        self.operation = operation
        self.fields = fields
    }

    public static func parse(_ data: Data) throws -> ModuleSchema {
        guard
            let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let op = o["operation"] as? String,
            let arr = o["fields"] as? [[String: Any]]
        else { throw EngineError("module schema is malformed") }

        let fields: [FieldSchema] = arr.compactMap { f in
            guard let name = f["name"] as? String, let t = f["type"] as? String else { return nil }
            let desc = f["description"] as? String ?? ""
            func num(_ k: String) -> Double? { (f[k] as? NSNumber)?.doubleValue }

            switch t {
            case "float", "double":
                return FieldSchema(name: name, description: desc, kind: .float,
                                   min: num("min") ?? -1, max: num("max") ?? 1,
                                   defaultValue: .number(num("default") ?? 0), options: [])
            case "int", "uint", "int8", "uint8", "short", "ushort":
                return FieldSchema(name: name, description: desc, kind: .int,
                                   min: num("min") ?? 0, max: num("max") ?? 1,
                                   defaultValue: .number(num("default") ?? 0), options: [])
            case "bool":
                return FieldSchema(name: name, description: desc, kind: .bool, min: 0, max: 1,
                                   defaultValue: .bool((f["default"] as? NSNumber)?.boolValue ?? false),
                                   options: [])
            case "enum":
                let raw = (f["values"] as? [[String: Any]] ?? []).compactMap { v -> (String, Int)? in
                    guard let n = v["name"] as? String, let val = (v["value"] as? NSNumber)?.intValue else { return nil }
                    return (n, val)
                }
                let labels = Self.enumLabels(raw.map(\.0))
                let options = zip(raw, labels).map { EnumOption(name: $0.0.0, value: $0.0.1, label: $0.1) }
                let defInt = num("default").map(Int.init) ?? 0
                let defName = options.first { $0.value == defInt }?.name ?? options.first?.name ?? ""
                return FieldSchema(name: name, description: desc, kind: .enumeration, min: 0, max: 0,
                                   defaultValue: .option(defName), options: options)
            default:
                return nil
            }
        }
        return ModuleSchema(operation: op, fields: fields)
    }

    /// EXPOSURE_MODE_MANUAL, EXPOSURE_MODE_DEFLICKER -> "manual", "deflicker":
    /// drop the prefix every member shares, lower-case, spaces for underscores.
    static func enumLabels(_ names: [String]) -> [String] {
        guard names.count > 1 else { return names.map(Self.humanize) }
        let parts = names.map { $0.split(separator: "_", omittingEmptySubsequences: false).map(String.init) }
        var prefix = 0
        while true {
            guard let first = parts.first, prefix < first.count else { break }
            let tok = first[prefix]
            if parts.allSatisfy({ prefix < $0.count - 1 && $0[prefix] == tok }) { prefix += 1 } else { break }
        }
        return parts.map { Self.humanize($0.dropFirst(prefix).joined(separator: "_")) }
    }

    static func humanize(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "_", with: " ").lowercased()
        return t.isEmpty ? s : t
    }
}

/// Output and working sizes of the open image.
public struct SessionInfo: Sendable, Equatable {
    public let processedWidth: Int
    public let processedHeight: Int
    public let workWidth: Int
    public let workHeight: Int
    /// The camera's orientation as the flip module's value (0...7), when the engine knows it. Simple mode's
    /// rotate button needs it: an explicit flip is absolute, so turning by 90 degrees starts from it.
    public let cameraOrientation: Int?

    public init(processedWidth: Int, processedHeight: Int, workWidth: Int, workHeight: Int, cameraOrientation: Int? = nil) {
        self.processedWidth = processedWidth
        self.processedHeight = processedHeight
        self.workWidth = workWidth
        self.workHeight = workHeight
        self.cameraOrientation = cameraOrientation
    }
}
