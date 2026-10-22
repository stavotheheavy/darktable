import DarkroomUI
import SwiftUI

/// The iPad and iPhone app: the same SwiftUI screens as the Mac, running the clean engine.
@main
struct VantageMobileApp: App {
    var body: some Scene {
        WindowGroup {
            DarkroomRoot()
        }
    }
}
