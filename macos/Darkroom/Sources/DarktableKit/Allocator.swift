import Darwin
import Foundation

/// The macOS allocator keeps every freed large block resident for reuse, and the engine's
/// pixel buffers are all large blocks: after six photos the process held about 2 GB of
/// freed memory on top of what it used. `malloc_zone_pressure_relief` does not give it
/// back, and the cache can only be switched off before the allocator starts, so a process
/// started without the switch runs itself again with it. Darkroom.app sets it through
/// LSEnvironment and never takes this path; a terminal launch does, once.
public enum Allocator {
    static let variable = "MallocLargeCache"

    public static func releaseFreedBlocksToTheSystem() {
        guard getenv(variable) == nil else { return }
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else { return }
        setenv(variable, "0", 1)
        execv(path, CommandLine.unsafeArgv)
        // exec failed: run on with the cache, which costs memory, not correctness
        unsetenv(variable)
    }
}
