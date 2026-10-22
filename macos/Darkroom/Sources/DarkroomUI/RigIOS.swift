#if !os(macOS)
import DarkroomEngineAPI
import Foundation
import SwiftUI

/// The iPad and iPhone side of the test rig. The Mac rig drives the app over a local socket
/// with mouse and key events; iOS has no such hook, so the iOS rig keeps the same control
/// names (each `.rig("id")` becomes the accessibility identifier) and XCUITest taps them.
/// Everything here is inert: the rig is off unless a test sets its environment.
@MainActor
public enum Rig {
    struct Entry { var frame: CGRect; var enabled: Bool }
    static var registry: [String: Entry] = [:]
    static var setters: [String: (Double) -> Void] = [:]
    static var comparing = false
    static var compareHook: (() -> Bool)?
    static let enabled = ProcessInfo.processInfo.environment["DARKROOM_RIG"] != nil

    static func canary(_ name: String) -> Bool {
        enabled && (ProcessInfo.processInfo.environment["DARKROOM_CANARY"] ?? "").split(separator: ",").contains { $0 == name }
    }

    public static func startIfRequested(model: DarkroomModel, library: LibraryModel,
                                        screen: @escaping () -> Screen, go: @escaping (Screen) -> Void,
                                        open: @escaping (String) -> Void) {}
}

/// Tags a control with its rig id, which is also its accessibility identifier.
struct RigTag: ViewModifier {
    let id: String
    func body(content: Content) -> some View { content.accessibilityIdentifier(id) }
}

extension View {
    func rig(_ id: String) -> some View { modifier(RigTag(id: id)) }
}

/// The Mac's HDR and automation runs have no iOS counterpart yet.
@MainActor
public enum AutoTest {
    public static func runIfRequested(model: DarkroomModel) async {}
}
#endif
