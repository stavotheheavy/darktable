import DarkroomEngineAPI
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few things the UI asks of the operating system, with one version per platform, so the
/// views themselves never import AppKit or UIKit for these.
public enum Platform {
    /// Backing scale of the main screen (2 when unknown).
    public static var backingScale: Double {
        #if os(macOS)
        Double(NSScreen.main?.backingScaleFactor ?? 2)
        #else
        Double(UIScreen.main.scale)
        #endif
    }

    /// Long edge of the largest screen, in backing pixels.
    public static var largestScreenLongSide: Double {
        #if os(macOS)
        Double(NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 0)
        #else
        let b = UIScreen.main.nativeBounds
        return Double(max(b.width, b.height))
        #endif
    }

    /// Current and potential extended-range headroom of the screen the photo is on.
    public static var screenHeadroom: (current: Double, potential: Double) {
        #if os(macOS)
        let screen = NSApp?.windows.first(where: { $0.isVisible && $0.frame.width > 400 })?.screen ?? NSScreen.main
        return (Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1),
                Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1))
        #else
        return (Double(UIScreen.main.currentEDRHeadroom), Double(UIScreen.main.potentialEDRHeadroom))
        #endif
    }

    /// Posted when the screen's parameters change, so the HDR preview can re-render for a new peak.
    public static var screenChangedNotification: Notification.Name {
        #if os(macOS)
        NSApplication.didChangeScreenParametersNotification
        #else
        UIScreen.brightnessDidChangeNotification
        #endif
    }

    /// The sRGB components of a color (a dark grey when it cannot be read).
    public static func rgb(of color: Color) -> (red: Double, green: Double, blue: Double) {
        #if os(macOS)
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(white: 0.25, alpha: 1)
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        #else
        var r: CGFloat = 0.25, g: CGFloat = 0.25, b: CGFloat = 0.25, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
        #endif
    }

    /// An iPhone: the one device the phone layout is for. The iPad, even held upright, keeps the wider layout.
    public static var isPhone: Bool {
        #if os(macOS)
        false
        #else
        UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    /// Puts text on the system clipboard.
    public static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// This machine in a sentence: "this Mac", "this iPad" or "this iPhone".
    public static var thisDevice: String {
        #if os(macOS)
        "this Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "this iPad" : "this iPhone"
        #endif
    }

    /// The name a sign-in is recorded under: this Mac, or this iPad or iPhone.
    public static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "this Mac"
        #else
        UIDevice.current.name
        #endif
    }

    /// The folder darktable's settings and caches live in. On iOS the app's own sandbox is the home folder.
    public static var homeDirectory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    /// Opens a web address in the browser.
    public static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// A text field has the keyboard, so plain keys belong to the text, not to the shortcuts.
    public static var typingInText: Bool {
        #if os(macOS)
        NSApp?.keyWindow?.firstResponder is NSText
        #else
        false
        #endif
    }
}
