import CoreGraphics
import DarktableKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Everything the darkroom view shows and does.
///
/// Rendering is latest-wins: one render is ever in flight, and if the sliders move
/// meanwhile the loop renders again with the newest values. While a slider is being
/// dragged the preview is smaller, so scrubbing stays as responsive as the engine allows.
@MainActor
@Observable
public final class DarkroomModel {
    // what the view shows
    public private(set) var image: CGImage?
    public private(set) var original: CGImage?
    public private(set) var fileName = "No image"
    public private(set) var status = "Open a raw to begin"
    public private(set) var lastMilliseconds: Double?
    public var openTool: Tool? = .light
    public var showingOriginal = false

    // edit state
    public private(set) var values: [String: Double] = [:]
    public private(set) var touched: Set<String> = []
    public private(set) var isScrubbing = false

    private let engine: Engine
    private var path: String?
    private var rendering = false
    private var wantsRender = false

    public init(engine: Engine = Engine()) {
        self.engine = engine
    }

    /// For layout checks and previews: a model that already holds a picture.
    public static func preview(image: CGImage, fileName: String) -> DarkroomModel {
        let m = DarkroomModel()
        m.image = image
        m.original = image
        m.fileName = fileName
        m.status = "\(image.width) x \(image.height)"
        return m
    }

    // MARK: lifecycle

    public func bootstrap(openingFirstArgument: Bool = true) async {
        let env = ProcessInfo.processInfo.environment
        let prefix = URL(fileURLWithPath: env["DT_PREFIX"] ?? "/Users/Chief/darktable/build/install")
        let home = FileManager.default.homeDirectoryForCurrentUser
        do {
            try await engine.start(
                prefix: prefix,
                configDir: home.appending(path: ".config/darktable-fork"),
                cacheDir: home.appending(path: ".cache/darktable-fork"))
        } catch {
            status = "Engine did not start: \(error)"
            return
        }
        if openingFirstArgument, CommandLine.arguments.count > 1 {
            await open(path: CommandLine.arguments[1])
        }
    }

    public func open(path: String) async {
        self.path = path
        fileName = URL(fileURLWithPath: path).lastPathComponent
        values = [:]
        touched = []
        original = nil
        status = "Developing…"
        requestRender()
    }

    // MARK: editing

    public func value(for spec: SliderSpec) -> Double { values[spec.id] ?? spec.neutral }

    public func set(_ spec: SliderSpec, to v: Double) {
        values[spec.id] = v
        touched.insert(spec.id)
        requestRender()
    }

    public func beginScrub() { isScrubbing = true }

    public func endScrub() {
        isScrubbing = false
        requestRender() // the full-size frame for the value the user stopped on
    }

    public func reset(_ tool: Tool) {
        for s in tool.sliders {
            values[s.id] = nil
            touched.remove(s.id)
        }
        requestRender()
    }

    public func toggle(_ tool: Tool) {
        openTool = (openTool == tool) ? nil : tool
    }

    public var isEdited: Bool { !touched.isEmpty }

    /// One stack entry per module that has a touched slider. A touched module gets all
    /// of its exposed fields, untouched ones at their neutral value, so moving one
    /// slider never drags in another field's module default.
    public func buildStack() -> [StackEntry] {
        let modules = Set(touched.compactMap { Catalog.spec($0)?.module })
        var fields: [String: [String: Double]] = [:]
        for spec in Catalog.all where modules.contains(spec.module) {
            fields[spec.module, default: [:]][spec.field] = values[spec.id] ?? spec.neutral
        }
        return fields.keys.sorted().map { StackEntry(operation: $0, params: fields[$0] ?? [:]) }
    }

    // MARK: rendering

    /// Returns once no render is running or queued. For headless callers and tests.
    public func settle() async {
        while rendering || wantsRender { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func requestRender() {
        wantsRender = true
        guard !rendering else { return }
        Task { await renderLoop() }
    }

    private func renderLoop() async {
        guard !rendering else { return }
        rendering = true
        defer { rendering = false }

        while wantsRender {
            wantsRender = false
            guard let path else { return }
            let stack = buildStack()
            let side = isScrubbing ? 700 : 1400
            do {
                let frame = try await engine.render(path: path, maxSide: side, stack: stack)
                image = frame.image
                lastMilliseconds = frame.milliseconds
                status = "\(frame.width) x \(frame.height)"
                if stack.isEmpty && !isScrubbing { original = frame.image }
            } catch {
                status = "\(error)"
            }
        }
    }

    // MARK: export

    /// Full-size JPEG of the current edit. The bound is the sensor's own long side, so
    /// darktable's upscale flag cannot enlarge the picture beyond the original.
    public func export(to url: URL) async {
        guard let path else { return }
        status = "Exporting…"
        let bound = Self.longSide(of: path) ?? 4096
        do {
            let frame = try await engine.render(path: path, maxSide: bound, stack: buildStack())
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw EngineError("cannot create \(url.lastPathComponent)") }
            CGImageDestinationAddImage(
                dest, frame.image,
                [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw EngineError("cannot write \(url.lastPathComponent)") }
            status = "Exported \(frame.width) x \(frame.height) to \(url.lastPathComponent)"
        } catch {
            status = "Export failed: \(error)"
        }
    }

    private static func longSide(of path: String) -> Int? {
        guard
            let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return max(w, h)
    }
}
