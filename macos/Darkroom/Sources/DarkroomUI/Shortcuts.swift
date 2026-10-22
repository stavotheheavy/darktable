import SwiftUI

/// Every keyboard shortcut in the app, in one place. The window's hidden buttons (DarkroomView), the help and the
/// manual (docs/manual.md, checked by `dtb-selftest --manual`) all read this table, so a shortcut cannot exist in one
/// and not the others. Owner's rule (2026-10-22): a new control or screen adds its shortcut here in the same change.
public struct Shortcut: Identifiable, Sendable {
    public let id: String
    /// What it does, in the user's words.
    public let title: String
    /// The keys as the manual prints them: ⌘⇧H, J, Esc.
    public let keys: String
    public let shortcut: KeyboardShortcut
    public let action: @MainActor @Sendable (DarkroomModel) -> Void
}

public enum Shortcuts {
    public static let all: [Shortcut] = [
        Shortcut(id: "hide-ui", title: "Hide or show the panels", keys: "\u{2318}\u{21E7}H",
                 shortcut: KeyboardShortcut("h", modifiers: [.command, .shift])) { $0.uiHidden.toggle() },
        Shortcut(id: "original", title: "Hold to compare with the original (press again to return)", keys: "\u{2318}\\",
                 shortcut: KeyboardShortcut("\\", modifiers: [.command])) { if $0.history.count > 1 { $0.showingOriginal.toggle() } },
        Shortcut(id: "close-menu", title: "Close the open menu", keys: "Esc",
                 shortcut: .cancelAction) { $0.proMenuOpen = nil },
        Shortcut(id: "clipping", title: "Show clipped highlights and crushed shadows", keys: "J",
                 shortcut: KeyboardShortcut("j", modifiers: [])) { $0.showClipping.toggle() },
        Shortcut(id: "all-on", title: "Switch every section in the panel on", keys: "\u{2325}\u{2318}A",
                 shortcut: KeyboardShortcut("a", modifiers: [.option, .command])) { $0.setAllProEffects(true) },
        Shortcut(id: "all-off", title: "Switch every section in the panel off (settings stay)", keys: "\u{2325}\u{2318}0",
                 shortcut: KeyboardShortcut("0", modifiers: [.option, .command])) { $0.setAllProEffects(false) },
        Shortcut(id: "panel-order", title: "Flip the panel between Newest and Pipeline order", keys: "\u{2325}\u{2318}O",
                 shortcut: KeyboardShortcut("o", modifiers: [.option, .command])) { $0.setProPanelOrder($0.proPanelOrder == .newest ? .pipeline : .newest) },
        Shortcut(id: "crop-tool", title: "Open or close the crop tool (crop, straighten, turn, flip)", keys: "C",
                 shortcut: KeyboardShortcut("c", modifiers: [])) { if $0.mode == .pro { $0.proMenuOpen = $0.proMenuOpen == .crop ? nil : .crop } },
        Shortcut(id: "test-card", title: "Show or hide the display test card (HDR steps and Display P3 colours)", keys: "\u{2325}\u{2318}T",
                 shortcut: KeyboardShortcut("t", modifiers: [.option, .command])) { if $0.presentsTexture { $0.setTestCard(!$0.testCard) } },
        Shortcut(id: "library", title: "Show or hide the library", keys: "\u{2318}\u{21E7}L",
                 shortcut: KeyboardShortcut("l", modifiers: [.command, .shift])) { $0.setLibraryShown(!$0.libraryShown) },
        Shortcut(id: "library-find", title: "Search the library (opens it if hidden)", keys: "\u{2318}F",
                 shortcut: KeyboardShortcut("f", modifiers: [.command])) { $0.setLibraryShown(true); $0.libraryFindSerial += 1 },
    ]

    /// Ids and keys, for the manual check: each must appear in docs/manual.md.
    public static var manualLines: [(id: String, keys: String)] { all.map { ($0.id, $0.keys) } }
}
