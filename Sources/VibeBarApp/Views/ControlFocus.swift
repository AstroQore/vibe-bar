import SwiftUI

/// The app's own button style: no chrome, no system focus ring, and a 1 pt
/// accent hairline on whichever control keyboard focus actually reaches.
///
/// Most controls in the popover, the Workbench, and the Layout editor are
/// drawn by hand — pills, segments, icon buttons, sidebar rows. As plain
/// buttons they kept the *system* focus effect, which draws a bright
/// system-accent rectangle around the control's bounding box: on a 22 pt
/// icon the ring is larger than the glyph, and it lights up after an
/// ordinary click, pointing at whatever was pressed last rather than at
/// anything the user needs. The old answer was marking each control
/// non-focusable, which silenced the ring by taking the control out of
/// keyboard navigation entirely.
///
/// This style replaces the ring instead of removing the control from the
/// loop. The containers switch the system effect off wholesale — see
/// ``SwiftUI/View/vibeBarControlFocus()`` — and this style draws its own
/// hairline in the app accent, following the control's real shape. Tab
/// order works, arrow keys work, and a keyboard user still sees exactly
/// where they are.
struct VibeBarButtonStyle: ButtonStyle {
    /// The corner the focus hairline follows. Should match the control's own
    /// background shape; defaults to the small-control radius used by the
    /// segment pills and icon buttons.
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        FocusRing(cornerRadius: cornerRadius) { configuration.label }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }

    /// The label, with the accent hairline around it while it has focus.
    ///
    /// A view of its own because `isFocused` is an environment value and a
    /// `ButtonStyle` is not a view — reading it needs something with a body,
    /// and that something has to sit *inside* the style so the answer is
    /// about this button rather than about its container.
    private struct FocusRing<Label: View>: View {
        let cornerRadius: CGFloat
        @ViewBuilder let label: Label

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            label.overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                }
            }
        }
    }
}

extension ButtonStyle where Self == VibeBarButtonStyle {
    /// The app's button: no chrome, no system focus ring, an accent hairline
    /// where keyboard focus lands.
    static var vibeBar: VibeBarButtonStyle { VibeBarButtonStyle() }

    /// The same, following a control whose corner is not the default 6 pt.
    static func vibeBar(cornerRadius: CGFloat) -> VibeBarButtonStyle {
        VibeBarButtonStyle(cornerRadius: cornerRadius)
    }
}

extension View {
    /// Switches the system focus effect off for a region of hand-drawn
    /// controls.
    ///
    /// Applied to the surface roots rather than to each button, because
    /// `isFocusEffectDisabled` is an environment value and the system ring
    /// is drawn by the button *around* its style — switching it off from
    /// inside a `ButtonStyle` cannot work, and switching it off once per
    /// surface cannot be forgotten by the next control somebody adds.
    func vibeBarControlFocus() -> some View {
        focusEffectDisabled()
    }

    /// Puts the system focus effect back, inside a region that switched it
    /// off.
    ///
    /// For the areas made of AppKit's own controls — Settings toggles,
    /// pickers, and text fields, the form sheets and popovers — which draw
    /// nothing of their own to say where keyboard focus is.
    func vibeBarSystemControlFocus() -> some View {
        focusEffectDisabled(false)
    }
}
