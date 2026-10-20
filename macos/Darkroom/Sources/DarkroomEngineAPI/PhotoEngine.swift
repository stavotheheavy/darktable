import Foundation

/// What the Darkroom UI needs from an image engine. `Engine` (darktable) and `CIEngine`
/// (the clean engine) both conform; a launch-time switch picks one.
///
/// Engines are actors so their session state is only touched in one place.
public protocol PhotoEngine: Actor {
    /// `prefix` is darktable's install prefix; engines that do not need one ignore it.
    func start(prefix: URL, configDir: URL, cacheDir: URL) async throws
    func shutdown() async

    func openSession(path: String, maxSide: Int) async throws
    func closeSession() async
    /// Stop the session render in progress, if any. Callable from any thread.
    nonisolated func cancelRender()
    func sessionRender(stack: [StackEntry], scale: Double) async throws -> RenderedFrame
    func sessionRenderRegion(stack: [StackEntry], scale: Double, x: Int, y: Int,
                             width: Int, height: Int) async throws -> RenderedFrame
    func sessionInfo() async -> SessionInfo?
    func sessionModules() async throws -> [ModuleInfo]
    func exportRender(path: String, maxSide: Int, stack: [StackEntry]) async throws -> RenderedFrame

    /// One-shot render of a file, no session kept.
    func render(path: String, maxSide: Int, stack: [StackEntry]) async throws -> RenderedFrame
    func moduleNames() async throws -> [String]
    func schema(for operation: String) async throws -> ModuleSchema
    func defaultValue(operation: String, field: String) async throws -> Double?
}

extension PhotoEngine {
    /// The common case: a one-shot render with no edits.
    public func render(path: String, maxSide: Int) async throws -> RenderedFrame {
        try await render(path: path, maxSide: maxSide, stack: [])
    }
}
