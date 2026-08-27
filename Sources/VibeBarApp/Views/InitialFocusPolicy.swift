import AppKit
import SwiftUI

/// Starts a newly presented surface with no control selected.
///
/// macOS picks the first eligible control the moment a window, sheet, or
/// popover becomes key. In a form that is a feature; in Vibe Bar it paints a
/// focus ring on whichever compact button happens to sit first in the
/// key-view loop of a surface most people only ever click or read. Clearing
/// the first responder once removes that accidental selection without
/// touching the key-view loop itself: Tab and arrow keys still enter
/// keyboard navigation normally, and their focus feedback stays visible.
struct InitialFocusProbe: NSViewRepresentable {
    let presentationID: UUID

    func makeNSView(context: Context) -> InitialFocusProbeView {
        InitialFocusProbeView(presentationID: presentationID)
    }

    func updateNSView(_ view: InitialFocusProbeView, context: Context) {
        view.beginPresentation(presentationID)
    }
}

/// The AppKit seam behind ``InitialFocusProbe``.
///
/// It reacts only to the probe entering a window or receiving a fresh
/// presentation token; it deliberately does not observe key-window changes,
/// so switching to another app and back can never erase a text field the
/// user is in the middle of editing.
@MainActor
final class InitialFocusController {
    private weak var window: NSWindow?
    private var presentationID: UUID?
    private var state = InitialFocusState()
    private var isScheduled = false

    func attach(to newWindow: NSWindow?, presentationID newPresentationID: UUID) {
        guard window !== newWindow || presentationID != newPresentationID else {
            scheduleIfNeeded()
            return
        }

        window = newWindow
        presentationID = newPresentationID
        state.attach(to: newWindow)
        isScheduled = false

        scheduleIfNeeded()
    }

    /// Clears the initial responder once for the current presentation.
    ///
    /// Returning whether the call consumed the one-shot keeps the contract
    /// testable. A focus the user has since established by keyboard or
    /// pointer is deliberately left alone.
    @discardableResult
    func clearInitialFocus(in candidate: NSWindow) -> Bool {
        state.consumeClear(for: candidate) {
            if candidate.firstResponder === candidate || candidate.firstResponder == nil {
                return true
            }
            return candidate.makeFirstResponder(nil)
        }
    }

    /// Two main-queue turns let SwiftUI and AppKit finish choosing their
    /// default first responder before the one-shot clear runs. The delay is
    /// scheduling, not a timer, so presentation animation never waits on it.
    private func scheduleIfNeeded() {
        guard let window,
              state.needsClear(for: window),
              !isScheduled
        else { return }

        isScheduled = true
        let scheduledPresentation = presentationID
        DispatchQueue.main.async { [weak self, weak window] in
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self else { return }
                self.isScheduled = false
                guard let window,
                      self.window === window,
                      self.presentationID == scheduledPresentation
                else { return }
                self.clearInitialFocus(in: window)
            }
        }
    }
}

/// The pure one-shot decision behind the AppKit controller.
///
/// Kept independent of `NSWindow` so the invariant can be exercised without
/// starting a second AppKit application inside SwiftPM's test host.
struct InitialFocusState {
    private var presentationID: ObjectIdentifier?
    private var didClear = false

    mutating func attach(to presentation: AnyObject?) {
        presentationID = presentation.map(ObjectIdentifier.init)
        didClear = false
    }

    func needsClear(for presentation: AnyObject) -> Bool {
        presentationID == ObjectIdentifier(presentation) && !didClear
    }

    @discardableResult
    mutating func consumeClear(
        for presentation: AnyObject,
        perform: () -> Bool
    ) -> Bool {
        guard needsClear(for: presentation), perform() else { return false }
        didClear = true
        return true
    }
}

/// A zero-area participant in SwiftUI's tree that can discover the hosting
/// window without taking layout space, a click, or an accessibility stop.
@MainActor
final class InitialFocusProbeView: NSView {
    private let controller = InitialFocusController()
    private var presentationID: UUID

    init(presentationID: UUID) {
        self.presentationID = presentationID
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller.attach(to: window, presentationID: presentationID)
    }

    func beginPresentation(_ id: UUID) {
        presentationID = id
        controller.attach(to: window, presentationID: id)
    }
}

/// Supplies a fresh token whenever SwiftUI presents a reusable hosting view.
/// `onAppear` is deliberately the trigger: app activation does not make an
/// already-visible root appear again, while reopening the popover, the
/// Workbench, or a sheet does — and each of those reopenings deserves
/// exactly one new clear.
private struct NoInitialFocusModifier: ViewModifier {
    @State private var presentationID = UUID()

    func body(content: Content) -> some View {
        content
            .background {
                InitialFocusProbe(presentationID: presentationID)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .onAppear { presentationID = UUID() }
    }
}

extension View {
    /// Makes this window, sheet, or popover start with no selected control.
    ///
    /// This is intentionally unrelated to `focusEffectDisabled`: it changes
    /// only the presentation's initial responder. Once the user presses Tab
    /// or an arrow key, native controls keep normal macOS focus feedback and
    /// Vibe Bar's own buttons draw their accent hairline — see
    /// ``VibeBarButtonStyle``.
    func vibeBarNoInitialFocus() -> some View {
        modifier(NoInitialFocusModifier())
    }
}
