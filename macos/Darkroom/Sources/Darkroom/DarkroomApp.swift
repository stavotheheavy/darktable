import AppKit
import DarkroomUI
import DarktableKit
import SwiftUI

@main
struct DarkroomApp: App {
    init() {
        // AppKit restores the last session's windows before SwiftUI's scenes are asked; quitting with the window
        // closed then meant no window at all on the next launch, and nothing to click. Read before launch finishes.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        Allocator.releaseFreedBlocksToTheSystem()
        // started from a terminal, a SwiftPM executable is not a regular app until told so;
        // without this the window opens behind everything and takes no keyboard focus
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("Vantage") {
            DarkroomRoot()
        }
        // no window restoration: a window closed before quitting must not mean no window at the next launch
        .restorationBehavior(.disabled)
        .defaultSize(width: 1280, height: 860)
    }
}
