import SwiftUI

/// The look from the design canvas (board S0): glass only on controls, flat fills inside
/// it, one flat accent, no shine. Anything coloured goes through here so it changes once.
enum Theme {
    /// periwinkle #a3b4ff
    static let accent = Color(red: 0.639, green: 0.706, blue: 1.0)
    /// text on the accent, #0e1226
    static let ink = Color(red: 0.055, green: 0.071, blue: 0.149)
    /// a selected row: a faint wash of the accent and a one point ring
    static let selectedFill = accent.opacity(0.20)
    static let selectedRing = accent.opacity(0.5)
}

/// The one primary action on a screen: a flat accent capsule, no gloss, no glow.
struct PrimaryCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(Theme.accent, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// A flat secondary control that sits inside a glass bar.
struct FlatCapsuleStyle: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .frame(height: 44)
            .lineLimit(1)
            .fixedSize()
            .background(on ? Theme.selectedFill : Color.white.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Theme.selectedRing : Color.white.opacity(0.16), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
