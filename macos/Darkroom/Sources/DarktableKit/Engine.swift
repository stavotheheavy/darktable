import CDtBridge
import CoreGraphics
import Foundation

public struct EngineError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One edit to apply on top of the image's default pipeline.
public struct StackEntry: Sendable {
    public var operation: String
    public var params: [String: Double]
    public var enabled: Bool

    public init(operation: String, params: [String: Double] = [:], enabled: Bool = true) {
        self.operation = operation
        self.params = params
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
        dtb_shutdown()
        started = false
    }

    /// Render a file (scratch-imported, never written next to the original) into a CGImage
    /// fitted inside `maxSide` x `maxSide`.
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
        let w = Int(frame.width), h = Int(frame.height), stride = Int(frame.stride)
        guard let pixels = frame.pixels else { throw EngineError("empty frame") }

        // dtb_frame_free releases the C buffer, so the image gets its own copy
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

        return RenderedFrame(image: image, width: w, height: h, milliseconds: ms)
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

    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { dtb_string_free(p) }
        return String(cString: p)
    }

    private static func json(_ stack: [StackEntry]) throws -> String {
        let objs: [[String: Any]] = stack.map {
            ["operation": $0.operation, "params": $0.params, "enabled": $0.enabled]
        }
        let data = try JSONSerialization.data(withJSONObject: objs)
        return String(decoding: data, as: UTF8.self)
    }
}
