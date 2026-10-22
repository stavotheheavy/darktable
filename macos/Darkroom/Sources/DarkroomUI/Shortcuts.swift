import AppKit
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

    /// Keys with no Command in them are routed by `KeyRouter`, which steps aside while a text field is being edited; a hidden
    /// SwiftUI button would swallow the letter or arrow before the field saw it. Command keys and Esc stay buttons.
    public var viaRouter: Bool { !shortcut.modifiers.contains(.command) && shortcut.key != .escape }
}

public enum Shortcuts {
    public static let all: [Shortcut] = [
        Shortcut(id: "undo", title: "Undo the last edit", keys: "\u{2318}Z",
                 shortcut: KeyboardShortcut("z", modifiers: [.command])) { $0.undo() },
        Shortcut(id: "redo", title: "Redo the edit you undid", keys: "\u{2318}\u{21E7}Z",
                 shortcut: KeyboardShortcut("z", modifiers: [.command, .shift])) { $0.redo() },
        Shortcut(id: "auto-edit", title: "Auto edit: white balance, exposure, highlights, shadows", keys: "A",
                 shortcut: KeyboardShortcut("a", modifiers: [])) { m in Task { await m.autoEdit() } },
        Shortcut(id: "sign-in", title: "Sign in to Databit Dev", keys: "\u{2325}\u{2318}U",
                 shortcut: KeyboardShortcut("u", modifiers: [.option, .command])) { m in if !m.cloudSignedIn { Task { await m.signInToCloud() } } },
        Shortcut(id: "send-gallery", title: "Send photos to a client gallery", keys: "\u{2325}\u{2318}G",
                 shortcut: KeyboardShortcut("g", modifiers: [.option, .command])) { $0.galleryRequest += 1 },
        Shortcut(id: "refresh-picks", title: "Refresh what clients picked in the galleries you sent", keys: "\u{2325}\u{2318}R",
                 shortcut: KeyboardShortcut("r", modifiers: [.option, .command])) { $0.picksRequest += 1 },
        Shortcut(id: "hide-ui", title: "Hide or show the panels", keys: "\u{2318}\u{21E7}H",
                 shortcut: KeyboardShortcut("h", modifiers: [.command, .shift])) { $0.uiHidden.toggle() },
        Shortcut(id: "original", title: "Hold to compare with the original (press again to return)", keys: "\u{2318}\\",
                 shortcut: KeyboardShortcut("\\", modifiers: [.command])) { if $0.history.count > 1 { $0.showingOriginal.toggle() } },
        Shortcut(id: "close-menu", title: "Close the shortcuts, or the open menu", keys: "Esc",
                 shortcut: .cancelAction) { if $0.helpShown { $0.helpShown = false } else { $0.proMenuOpen = nil } },
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
        Shortcut(id: "help", title: "Show or hide this list", keys: "?",
                 shortcut: KeyboardShortcut("?", modifiers: [])) { $0.helpShown.toggle() },
        Shortcut(id: "help-cmd", title: "Show or hide this list (the Mac way)", keys: "\u{2318}/",
                 shortcut: KeyboardShortcut("/", modifiers: [.command])) { $0.helpShown.toggle() },
        Shortcut(id: "zoom-fit", title: "Zoom: fit the photo", keys: "\u{2318}0",
                 shortcut: KeyboardShortcut("0", modifiers: [.command])) { $0.zoom = .fit },
        Shortcut(id: "zoom-100", title: "Zoom: 100%", keys: "\u{2318}1",
                 shortcut: KeyboardShortcut("1", modifiers: [.command])) { $0.zoom = .actual },
        Shortcut(id: "zoom-200", title: "Zoom: 200%", keys: "\u{2318}2",
                 shortcut: KeyboardShortcut("2", modifiers: [.command])) { $0.zoom = .double },
        Shortcut(id: "menu-modules", title: "Open the library with its search ready", keys: "M",
                 shortcut: KeyboardShortcut("m", modifiers: [])) { $0.setLibraryShown(true); $0.libraryFindSerial += 1 },
        Shortcut(id: "mask-brush", title: "Mask tool: brush", keys: "B",
                 shortcut: KeyboardShortcut("b", modifiers: [])) { m in guard m.mode == .pro else { return }; Task { await m.applyLibraryMask(.brush) } },
        Shortcut(id: "mask-lasso", title: "Mask tool: lasso", keys: "L",
                 shortcut: KeyboardShortcut("l", modifiers: [])) { m in guard m.mode == .pro else { return }; Task { await m.applyLibraryMask(.lasso) } },
        Shortcut(id: "mask-linear", title: "Mask tool: linear gradient", keys: "G",
                 shortcut: KeyboardShortcut("g", modifiers: [])) { m in guard m.mode == .pro else { return }; Task { await m.applyLibraryMask(.linear) } },
        Shortcut(id: "mask-radial", title: "Mask tool: radial gradient", keys: "R",
                 shortcut: KeyboardShortcut("r", modifiers: [])) { m in guard m.mode == .pro else { return }; Task { await m.applyLibraryMask(.radial) } },
        Shortcut(id: "menu-presets", title: "Open or close the Presets (looks) menu", keys: "P",
                 shortcut: KeyboardShortcut("p", modifiers: [])) { $0.toggleMenu(.presets) },
        Shortcut(id: "menu-history", title: "Open or close History", keys: "H",
                 shortcut: KeyboardShortcut("h", modifiers: [])) { $0.toggleMenu(.history) },
        Shortcut(id: "panel-up", title: "Panel: previous section", keys: "\u{2191}",
                 shortcut: KeyboardShortcut(.upArrow, modifiers: [])) { $0.moveSectionFocus(-1) },
        Shortcut(id: "panel-down", title: "Panel: next section (it opens)", keys: "\u{2193}",
                 shortcut: KeyboardShortcut(.downArrow, modifiers: [])) { $0.moveSectionFocus(1) },
        Shortcut(id: "slider-prev", title: "Panel: previous slider in the section", keys: "[",
                 shortcut: KeyboardShortcut("[", modifiers: [])) { $0.moveFieldFocus(-1) },
        Shortcut(id: "slider-next", title: "Panel: next slider in the section", keys: "]",
                 shortcut: KeyboardShortcut("]", modifiers: [])) { $0.moveFieldFocus(1) },
        Shortcut(id: "nudge-down", title: "Slider: lower by a hundredth of its range", keys: "\u{2190}",
                 shortcut: KeyboardShortcut(.leftArrow, modifiers: [])) { $0.nudgeFocused(-1) },
        Shortcut(id: "nudge-up", title: "Slider: raise by a hundredth of its range", keys: "\u{2192}",
                 shortcut: KeyboardShortcut(.rightArrow, modifiers: [])) { $0.nudgeFocused(1) },
        Shortcut(id: "nudge-down-big", title: "Slider: lower ten times as much", keys: "\u{21E7}\u{2190}",
                 shortcut: KeyboardShortcut(.leftArrow, modifiers: [.shift])) { $0.nudgeFocused(-10) },
        Shortcut(id: "nudge-up-big", title: "Slider: raise ten times as much", keys: "\u{21E7}\u{2192}",
                 shortcut: KeyboardShortcut(.rightArrow, modifiers: [.shift])) { $0.nudgeFocused(10) },
        Shortcut(id: "nudge-down-fine", title: "Slider: lower a tenth as much", keys: "\u{2325}\u{2190}",
                 shortcut: KeyboardShortcut(.leftArrow, modifiers: [.option])) { $0.nudgeFocused(-0.1) },
        Shortcut(id: "nudge-up-fine", title: "Slider: raise a tenth as much", keys: "\u{2325}\u{2192}",
                 shortcut: KeyboardShortcut(.rightArrow, modifiers: [.option])) { $0.nudgeFocused(0.1) },
        Shortcut(id: "slider-reset", title: "Slider: back to its default", keys: "\u{232B}",
                 shortcut: KeyboardShortcut(.delete, modifiers: [])) { $0.resetFocused() },
        Shortcut(id: "section-power", title: "Section: switch its effect on or off", keys: "E",
                 shortcut: KeyboardShortcut("e", modifiers: [])) { $0.toggleFocusedEffect() },
        Shortcut(id: "section-fold", title: "Section: fold or unfold", keys: "F",
                 shortcut: KeyboardShortcut("f", modifiers: [])) { $0.toggleFocusedFold() },
    ]

    /// The help overlay's groups, by shortcut id. `--ui` fails when a shortcut is in no group.
    static let groupIDs: [(title: String, ids: [String])] = [
        ("Edit", ["undo", "redo", "auto-edit", "original", "crop-tool"]),
        ("The panel (Pro)", ["panel-up", "panel-down", "slider-prev", "slider-next", "nudge-down", "nudge-up",
                             "nudge-down-big", "nudge-up-big", "nudge-down-fine", "nudge-up-fine", "slider-reset",
                             "section-power", "section-fold", "all-on", "all-off", "panel-order"]),
        ("Menus and library", ["menu-modules", "menu-presets", "menu-history", "library", "library-find", "close-menu"]),
        ("Account", ["sign-in", "send-gallery", "refresh-picks"]),
        ("View", ["zoom-fit", "zoom-100", "zoom-200", "clipping", "test-card", "hide-ui", "help", "help-cmd"]),
    ]
    public static var groups: [(title: String, shortcuts: [Shortcut])] {
        groupIDs.map { g in (g.title, g.ids.compactMap { id in all.first { $0.id == id } }) }
    }

    /// Ids and keys, for the manual check: each must appear in docs/manual.md.
    public static var manualLines: [(id: String, keys: String)] { all.map { ($0.id, $0.keys) } }
}

/// Routes the keys that carry no Command (letters, arrows, [ ], Delete) to the registry, once per window. It returns the event
/// untouched while a text field is being edited, so typing and the field's own arrow keys work. Command keys and Esc are
/// hidden buttons in DarkroomView.
@MainActor
public enum KeyRouter {
    /// The registry entry a key press means, if any; `key` is the press without Shift (an arrow is its private-use scalar).
    public static func match(key: Character, flags: NSEvent.ModifierFlags) -> Shortcut? {
        let held = flags.intersection([.command, .option, .shift, .control])
        // a shifted symbol ("?") is typed with Shift on every layout: its Shift does not count
        let symbol = "?{}|:\"<>~!@#$%^&*()_+".contains(key)
        return Shortcuts.all.first { s in
            guard s.viaRouter, Self.character(s.shortcut.key) == key else { return false }
            var want: NSEvent.ModifierFlags = []
            if s.shortcut.modifiers.contains(.shift) { want.insert(.shift) }
            if s.shortcut.modifiers.contains(.option) { want.insert(.option) }
            if s.shortcut.modifiers.contains(.control) { want.insert(.control) }
            return symbol ? held.subtracting(.shift) == want.subtracting(.shift) : held == want
        }
    }

    private static func character(_ k: KeyEquivalent) -> Character {
        // SwiftUI's Delete is backspace (U+0008); the keyboard reports it as U+007F
        k == .delete ? "\u{7F}" : Character(k.character.lowercased())
    }

    private static var monitor: Any?
    /// Installs the window's key monitor once; later calls do nothing.
    public static func install(for model: DarkroomModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model, !DarkroomModel.typingInText, !event.isARepeat || Self.repeats(event),
                  let ch = event.charactersIgnoringModifiers?.first, let s = match(key: Character(ch.lowercased()), flags: event.modifierFlags)
            else { return event }
            MainActor.assumeIsolated { s.action(model) }
            return nil
        }
    }

    /// Holding an arrow key keeps nudging; holding a toggle key (E, F, M, P, H, ?, J, C) does not flicker.
    private static func repeats(_ event: NSEvent) -> Bool {
        guard let ch = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else { return false }
        return (0xF700...0xF703).contains(ch) || ch == 0x7F
    }
}
