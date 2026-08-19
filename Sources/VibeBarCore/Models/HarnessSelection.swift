import Foundation

/// What a click on a harness filter chip means, as pure arithmetic.
///
/// Usage Stats and Sessions both draw the same harness-primary chip row (an
/// "All" chip, then one muted company section head per group followed by its
/// harnesses) and both used to re-implement the toggle rules on their own
/// view model. The rules live here instead, so the two surfaces cannot drift
/// and the behaviour is testable without a window.
///
/// The selection is `Set<Harness>?`:
///
/// - `nil` — **every** harness. The unfiltered query.
/// - `[]`  — **no** harness. An explicit state the user reaches by clicking
///   "All" while everything is already lit, or by turning the last chip off.
///   It queries nothing, and the page says so rather than showing zeroes.
/// - anything else — exactly those harnesses.
///
/// Empty used to be folded back into `nil`, which made "deselect everything"
/// unsayable: the last chip going dark silently re-selected all of them.
public enum HarnessSelection {
    /// True when `selection` covers every option — either because it is `nil`
    /// or because it happens to contain all of them.
    public static func isEverything(_ selection: Set<Harness>?, options: [Harness]) -> Bool {
        guard let selection else { return true }
        guard !options.isEmpty else { return false }
        return options.allSatisfy(selection.contains)
    }

    /// True for the explicit empty selection — the state that queries nothing.
    public static func isNothing(_ selection: Set<Harness>?) -> Bool {
        selection?.isEmpty ?? false
    }

    /// What the "All" chip does: everything selected turns everything off,
    /// anything else (a partial selection, or nothing at all) turns
    /// everything back on.
    public static func toggleAll(_ selection: Set<Harness>?, options: [Harness]) -> Set<Harness>? {
        isEverything(selection, options: options) ? [] : nil
    }

    /// ⌥-click on a harness chip: keep only that one.
    public static func solo(_ harness: Harness, options: [Harness]) -> Set<Harness>? {
        normalized([harness], options: options)
    }

    /// A plain click on one chip, or on the company section head that stands
    /// for several: present in full means turn them off, otherwise turn them
    /// on. The company chips keep this toggle-group behaviour unchanged.
    public static func toggle(
        _ harnesses: Set<Harness>,
        in selection: Set<Harness>?,
        options: [Harness]
    ) -> Set<Harness>? {
        guard !harnesses.isEmpty else { return selection }
        var next = selection ?? Set(options)
        if harnesses.allSatisfy(next.contains) {
            next.subtract(harnesses)
        } else {
            next.formUnion(harnesses)
        }
        return normalized(next, options: options)
    }

    /// Everything selected is the same statement as "no filter", and saying
    /// it that way keeps the chip row and the query in agreement. An empty
    /// result stays empty, because none-selected is now a state the user can
    /// actually mean.
    public static func normalized(
        _ selection: Set<Harness>?,
        options: [Harness]
    ) -> Set<Harness>? {
        guard let selection else { return nil }
        if selection.isEmpty { return [] }
        return isEverything(selection, options: options) ? nil : selection
    }
}
