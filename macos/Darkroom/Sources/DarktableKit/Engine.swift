import CDtBridge
import CoreGraphics
import Foundation

public struct EngineError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One edit to apply on top of the image's imported state.
public struct StackEntry: Sendable {
    public var operation: String
    public var multiPriority: Int
    public var params: [String: ParamValue]
    public var blend: [String: ParamValue]
    public var enabled: Bool

    public init(operation: String, multiPriority: Int = 0, params: [String: ParamValue] = [:],
                blend: [String: ParamValue] = [:], enabled: Bool = true) {
        self.operation = operation
        self.multiPriority = multiPriority
        self.params = params
        self.blend = blend
        self.enabled = enabled
    }
}

public struct RenderedFrame: @unchecked Sendable {
    public let image: CGImage
    public let width: Int
    public let height: Int
    public let milliseconds: Double
}

/// Owns darktable's headless engine.
///
/// darktable's core was written for one UI thread, so every call is pinned to a
/// single serial queue instead of hopping around the cooperative pool.
public actor Engine {
    private let queue = DispatchSerialQueue(label: "darktable.engine", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var started = false
    private var session: OpaquePointer?   // dtb_session*
    private var sessionMaxSide = 0

    public init() {}

    /// `prefix` is the install prefix of the fork (it holds share/darktable and lib/darktable).
    public func start(prefix: URL, configDir: URL, cacheDir: URL) throws {
        guard !started else { return }
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        var err: UnsafeMutablePointer<CChar>?
        let rc = dtb_init(
            prefix.appending(path: "share/darktable").path,
            prefix.appending(path: "lib/darktable").path,
            configDir.path,
            cacheDir.path,
            nil,
            &err
        )
        if rc != 0 { throw EngineError(Self.take(err) ?? "dtb_init failed (\(rc))") }
        started = true
    }

    public func shutdown() {
        guard started else { return }
        closeSession()
        dtb_shutdown()
        started = false
    }

    // MARK: persistent session

    /// Keep one image open so edits re-run only from the changed module onward.
    /// Frames come out at the same size for the life of the session.
    public func openSession(path: String, maxSide: Int) throws {
        guard started else { throw EngineError("engine not started") }
        closeSession()
        var err: UnsafeMutablePointer<CChar>?
        guard let s = dtb_session_open(path, 0, Int32(maxSide), Int32(maxSide), &err) else {
            throw EngineError(Self.take(err) ?? "could not open the image")
        }
        session = s
        sessionMaxSide = maxSide
    }

    public func closeSession() {
        if let s = session { dtb_session_close(s) }
        session = nil
    }

    public var hasSession: Bool { session != nil }

    /// Render the open image with exactly `stack` applied.
    public func sessionRender(stack: [StackEntry] = []) throws -> RenderedFrame {
        guard let session else { throw EngineError("no image is open") }
        let stackJSON: String? = stack.isEmpty ? nil : try Self.json(stack)
        let t0 = DispatchTime.now().uptimeNanoseconds

        var frame = dtb_frame()
        var err: UnsafeMutablePointer<CChar>?
        let rc = dtb_session_render(session, stackJSON, &frame, &err)
        if rc != 0 { throw EngineError(Self.take(err) ?? "render failed (\(rc))") }
        defer { dtb_frame_free(&frame) }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        return try Self.wrap(frame, milliseconds: ms)
    }

    /// Full-size render for export. The one-shot path refuses a file a session still
    /// holds, so the session is closed for the export and reopened afterwards.
    public func exportRender(path: String, maxSide: Int, stack: [StackEntry]) throws -> RenderedFrame {
        let size = sessionMaxSide
        let wasOpen = session != nil
        closeSession()
        defer { if wasOpen { try? openSession(path: path, maxSide: size) } }
        return try render(path: path, maxSide: maxSide, stack: stack)
    }

    /// The session's modules in pipeline order, in the imported state.
    public func sessionModules() throws -> [ModuleInfo] {
        guard let session else { throw EngineError("no image is open") }
        var err: UnsafeMutablePointer<CChar>?
        guard let c = dtb_session_modules_json(session, &err) else {
            throw EngineError(Self.take(err) ?? "could not list modules")
        }
        defer { dtb_string_free(c) }
        return try ModuleInfo.parse(Data(String(cString: c).utf8))
    }

    public func sessionInfo() -> SessionInfo? {
        guard let session else { return nil }
        var pw: Int32 = 0, ph: Int32 = 0, ww: Int32 = 0, wh: Int32 = 0
        dtb_session_info(session, &pw, &ph, &ww, &wh)
        return SessionInfo(processedWidth: Int(pw), processedHeight: Int(ph),
                           workWidth: Int(ww), workHeight: Int(wh))
    }

    /// One region at an explicit scale (1.0 = full-resolution output), in that scaled
    /// image's pixels. What a zoomed or panned view needs.
    public func sessionRenderRegion(stack: [StackEntry], scale: Double, x: Int, y: Int,
                                    width: Int, height: Int) throws -> RenderedFrame {
        guard let session else { throw EngineError("no image is open") }
        let stackJSON: String? = stack.isEmpty ? nil : try Self.json(stack)
        let t0 = DispatchTime.now().uptimeNanoseconds

        var frame = dtb_frame()
        var err: UnsafeMutablePointer<CChar>?
        let rc = dtb_session_render_region(session, stackJSON, scale, Int32(x), Int32(y),
                                           Int32(width), Int32(height), &frame, &err)
        if rc != 0 { throw EngineError(Self.take(err) ?? "render failed (\(rc))") }
        defer { dtb_frame_free(&frame) }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        return try Self.wrap(frame, milliseconds: ms)
    }

    private var schemas: [String: ModuleSchema] = [:]

    /// A module's parameter fields: names, ranges, defaults, enum members.
    public func schema(for operation: String) throws -> ModuleSchema {
        if let s = schemas[operation] { return s }
        guard started else { throw EngineError("engine not started") }
        var err: UnsafeMutablePointer<CChar>?
        guard let c = dtb_module_schema_json(operation, &err) else {
            throw EngineError(Self.take(err) ?? "no schema for \(operation)")
        }
        defer { dtb_string_free(c) }
        let s = try ModuleSchema.parse(Data(String(cString: c).utf8))
        schemas[operation] = s
        return s
    }

    // MARK: one-shot

    /// Render a file (scratch-imported, never written next to the original) into a CGImage
    /// fitted inside `maxSide` x `maxSide`. Builds and discards a pipeline every call.
    public func render(path: String, maxSide: Int, stack: [StackEntry] = []) throws -> RenderedFrame {
        guard started else { throw EngineError("engine not started") }

        let stackJSON: String? = stack.isEmpty ? nil : try Self.json(stack)
        let t0 = DispatchTime.now().uptimeNanoseconds

        var frame = dtb_frame()
        var err: UnsafeMutablePointer<CChar>?
        let rc = dtb_render(path, 0, Int32(maxSide), Int32(maxSide), stackJSON, &frame, &err)
        if rc != 0 { throw EngineError(Self.take(err) ?? "render failed (\(rc))") }
        defer { dtb_frame_free(&frame) }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        return try Self.wrap(frame, milliseconds: ms)
    }

    /// Names of every module darktable knows, straight from its introspection.
    public func moduleNames() throws -> [String] {
        guard started else { throw EngineError("engine not started") }
        guard let c = dtb_list_modules_json() else { throw EngineError("no module list") }
        defer { dtb_string_free(c) }
        let data = Data(String(cString: c).utf8)
        let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return arr.compactMap { $0["operation"] as? String }
    }

    /// The default value of one parameter field, read from the module's introspection.
    public func defaultValue(operation: String, field: String) throws -> Double? {
        guard started else { throw EngineError("engine not started") }
        var err: UnsafeMutablePointer<CChar>?
        guard let c = dtb_module_schema_json(operation, &err) else {
            throw EngineError(Self.take(err) ?? "no schema for \(operation)")
        }
        defer { dtb_string_free(c) }
        let obj = try JSONSerialization.jsonObject(with: Data(String(cString: c).utf8)) as? [String: Any]
        let fields = obj?["fields"] as? [[String: Any]] ?? []
        return fields.first { ($0["name"] as? String) == field }.flatMap { $0["default"] as? Double }
    }

    // MARK: helpers

    /// dtb_frame_free releases the C buffer, so the image gets its own copy.
    private static func wrap(_ frame: dtb_frame, milliseconds: Double) throws -> RenderedFrame {
        let w = Int(frame.width), h = Int(frame.height), stride = Int(frame.stride)
        guard let pixels = frame.pixels else { throw EngineError("empty frame") }
        let data = Data(bytes: pixels, count: stride * h)
        guard
            let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw EngineError("could not wrap the frame as an image") }
        return RenderedFrame(image: image, width: w, height: h, milliseconds: milliseconds)
    }

    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { dtb_string_free(p) }
        return String(cString: p)
    }

    private static func json(_ stack: [StackEntry]) throws -> String {
        let objs: [[String: Any]] = stack.map { e in
            var o: [String: Any] = [
                "operation": e.operation,
                "multi_priority": e.multiPriority,
                "enabled": e.enabled,
                "params": e.params.mapValues(\.jsonObject),
            ]
            if !e.blend.isEmpty { o["blend"] = e.blend.mapValues(\.jsonObject) }
            return o
        }
        let data = try JSONSerialization.data(withJSONObject: objs)
        return String(decoding: data, as: UTF8.self)
    }
}
