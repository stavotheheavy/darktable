import DarkroomEngineAPI
import DarkroomCI
#if os(macOS)
import DarktableKit
#endif
import Foundation

/// Picks the engine for this launch. On the Mac, darktable stays the default and the clean
/// engine is opt-in (`DARKROOM_ENGINE=ci`). iOS and iPad have no darktable, so they always
/// run the clean engine.
public enum EngineChoice {
    public static func make(env: [String: String] = ProcessInfo.processInfo.environment) -> any PhotoEngine {
        switch env["DARKROOM_ENGINE"]?.lowercased() {
        case "ci": CIEngine()
        #if os(macOS)
        default: Engine()
        #else
        default: CIEngine()
        #endif
        }
    }
}
