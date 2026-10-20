import DarkroomCI
import DarktableKit
import Foundation

/// Picks the engine for this launch. darktable stays the default; the clean engine is
/// opt-in until it passes its gate: `DARKROOM_ENGINE=ci`.
public enum EngineChoice {
    public static func make(env: [String: String] = ProcessInfo.processInfo.environment) -> any PhotoEngine {
        switch env["DARKROOM_ENGINE"]?.lowercased() {
        case "ci": CIEngine()
        default: Engine()
        }
    }
}
