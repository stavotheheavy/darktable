import AppKit
import DarkroomCore
import DarktableKit
import Foundation

/// Driving Pro's panel from the keyboard: up and down pick a section, `[` and `]` pick a slider in it, the left and right
/// arrows nudge that slider, Delete puts it back, E switches the section's effect, F folds it. The place is
/// `focusEntryID` and `focusFieldName`; the panel draws an outline on the section and a dot beside the slider.
extension DarkroomModel {
    /// A text field is being edited: plain keys belong to it, not to the shortcuts.
    @MainActor static var typingInText: Bool { NSApp?.keyWindow?.firstResponder is NSText }

    /// The sliders of a section the keys can reach: numeric fields that show a slider (a soft range), the ones the panel shows.
    public func focusableFields(_ e: ProEntry) -> [(module: ModuleInfo, field: FieldSchema)] {
        if e.modules[0].operation == "tonecurve", e.modules[0].multiPriority == 0, curveNodes != nil { return [] }
        var out: [(module: ModuleInfo, field: FieldSchema)] = []
        for m in e.modules {
            guard let schema = schema(for: m) else { continue }
            for f in shownFields(m, schema.fields) {
                let numeric = f.kind == .float || f.kind == .int
                if numeric, SoftRange.range(operation: m.operation, field: f) != nil { out.append((module: m, field: f)) }
            }
        }
        return out
    }

    public var focusedEntry: ProEntry? { focusEntryID.flatMap { id in proPanelEntries.first { $0.id == id } } }

    public var focusedField: (module: ModuleInfo, field: FieldSchema)? {
        guard let e = focusedEntry else { return nil }
        let fs = focusableFields(e)
        return fs.first { $0.field.name == focusFieldName } ?? fs.first
    }

    /// The slider the keys act on, as "module id / field name", for the panel to mark.
    public func isFocusedField(_ m: ModuleInfo, _ f: FieldSchema) -> Bool {
        guard let c = focusedField else { return false }
        return c.module.id == m.id && c.field.name == f.name
    }

    private var keysReachPanel: Bool { mode == .pro && !uiHidden }

    /// Up (-1) and down (+1) in the panel. The section opens, and its first slider is the one the arrows nudge.
    public func moveSectionFocus(_ d: Int) {
        guard keysReachPanel else { return }
        let entries = proPanelEntries
        guard !entries.isEmpty else { return }
        let at = entries.firstIndex { $0.id == focusEntryID }
        let next = at.map { min(max($0 + d, 0), entries.count - 1) } ?? (d > 0 ? 0 : entries.count - 1)
        focusEntryID = entries[next].id
        proOpen.insert(entries[next].id)
        focusFieldName = focusableFields(entries[next]).first?.field.name
    }

    /// `[` (-1) and `]` (+1): the previous or next slider in the focused section.
    public func moveFieldFocus(_ d: Int) {
        guard keysReachPanel else { return }
        if focusedEntry == nil { moveSectionFocus(1) }
        guard let e = focusedEntry else { return }
        let fs = focusableFields(e)
        guard !fs.isEmpty else { return }
        let at = fs.firstIndex { $0.field.name == focusFieldName } ?? 0
        focusFieldName = fs[min(max(at + d, 0), fs.count - 1)].field.name
    }

    /// Left and right: `steps` hundredths of the slider's range (a whole number for an integer slider), kept inside the
    /// range. Shift is ten steps, Option a tenth of one. A held key is one History step (the same target merges).
    public func nudgeFocused(_ steps: Double) {
        guard keysReachPanel, let (m, f) = focusedField, let soft = SoftRange.range(operation: m.operation, field: f) else { return }
        let current = value(m, f).double ?? 0
        let lo = min(soft.lowerBound, current), hi = max(soft.upperBound, current)
        var step = (hi - lo) / 100
        if f.kind == .int { step = max(1, step.rounded()) }
        var next = min(max(current + steps * step, lo), hi)
        if f.kind == .int { next = next.rounded() }
        guard next != current else { return }
        setParam(m, f, to: .number(next))
    }

    /// Delete: the focused slider back to its default.
    public func resetFocused() {
        guard keysReachPanel, let (m, f) = focusedField else { return }
        resetParam(m, f)
    }

    /// E: the focused section's effect on or off.
    public func toggleFocusedEffect() {
        guard keysReachPanel, let e = focusedEntry, !e.modules.allSatisfy(\.hideEnableButton) else { return }
        toggleProEffect(e)
    }

    /// F: the focused section folded or unfolded.
    public func toggleFocusedFold() {
        guard keysReachPanel, let e = focusedEntry else { return }
        toggleProFold(e)
    }

    /// The header's dropdowns by key: the same one again closes it.
    public func toggleMenu(_ k: ProMenuKind) {
        guard mode == .pro else { return }
        proMenuOpen = proMenuOpen == k ? nil : k
    }
}
