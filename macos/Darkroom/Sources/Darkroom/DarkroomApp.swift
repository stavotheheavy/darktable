import AppKit
import DarkroomUI
import DarktableKit
import SwiftUI

@main
struct DarkroomApp: App {
    init() {
        Allocator.releaseFreedBlocksToTheSystem()
        // started from a terminal, a SwiftPM executable is not a regular app until told so;
        // without this the window opens behind everything and takes no keyboard focus
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("Darkroom") {
            DarkroomRoot()
        }
        .defaultSize(width: 1280, height: 860)
    }
}
