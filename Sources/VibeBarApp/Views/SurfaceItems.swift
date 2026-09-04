import SwiftUI
import VibeBarCore

/// The Layout Studio arranges a real popover page or a real mini window, not
/// a drawing of one. These are the hooks the real surfaces give it.
///
/// Three things cross the boundary, all through the environment so a surface
/// that is not on the stage never knows any of this exists:
///
/// - **Frames.** Each arrangeable card or cell is tagged with
///   `surfaceItem(_:)`. Outside the Studio the tag is inert; inside, it
///   reports the item's frame into `SurfaceItemFrames`, in the surface's own
///   unscaled coordinates, so the Studio can ask "what is under the pointer".
/// - **The lifted item.** While one item is being dragged, the surface draws
///   it as a placeholder — dimmed, still in layout — and the Studio carries a
///   picture of it under the pointer.
/// - **A provisional arrangement.** The Studio re-slots the dragged item on
///   every crossing and hands the surface the columns (or the field order)
///   that would result. The surface draws that instead of the saved one, so
///   the cards make room live, and nothing is written until the drop.
enum SurfaceCoordinates {
    /// Coordinate space every tagged item reports its frame in: the surface
    /// before the Studio scales it.
    static let space = "vibebar.studio.surface"
}

/// Where the things on a surface are, as the surface last drew them.
///
/// A plain class rather than an `ObservableObject` on purpose: frames move on
/// every pass of a reflow animation, and nothing should re-render because of
/// that. The Studio reads them when the pointer asks a question.
@MainActor
final class SurfaceItemFrames {
    private(set) var frames: [String: CGRect] = [:]

    func report(_ frame: CGRect, for id: String) {
        frames[id] = frame
    }

    func forget(_ id: String) {
        frames.removeValue(forKey: id)
    }

    func removeAll() {
        frames.removeAll()
    }

    func frame(of id: String) -> CGRect? {
        frames[id]
    }

    /// The item under `point`. When items nest — a group drawn around its
    /// cells — the smallest wins, because the cell is what the user meant.
    func item(at point: CGPoint) -> String? {
        frames
            .filter { $0.value.contains(point) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?
            .key
    }
}

/// What a popover page draws instead of its saved arrangement while it is on
/// the Studio's stage.
///
/// `arrangement == nil` means "the resolved arrangement, through the
/// fixed-column path". That matters for the Overview in `auto`, which
/// normally hands its cards to the live masonry balancer: the Studio asks for
/// the same arrangement drawn as fixed columns from the moment it opens, so
/// that starting a drag does not switch layouts under the pointer.
struct StudioPageOverride: Equatable {
    let page: PageLayoutPageID
    let arrangement: PageLayoutArrangement?
}

/// The field order a mini window draws instead of its saved one while a drag
/// is in flight on the Studio's stage.
struct StudioMiniOrderOverride: Equatable {
    let windowID: UUID
    let fieldIds: [String]
}

private struct SurfaceItemFramesKey: EnvironmentKey {
    static let defaultValue: SurfaceItemFrames? = nil
}

private struct LiftedSurfaceItemKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct StudioPageOverrideKey: EnvironmentKey {
    static let defaultValue: StudioPageOverride? = nil
}

private struct StudioMiniOrderOverrideKey: EnvironmentKey {
    static let defaultValue: StudioMiniOrderOverride? = nil
}

extension EnvironmentValues {
    /// Set by the Studio on the surface it is arranging; `nil` everywhere else.
    var surfaceItemFrames: SurfaceItemFrames? {
        get { self[SurfaceItemFramesKey.self] }
        set { self[SurfaceItemFramesKey.self] = newValue }
    }

    /// The item currently carried under the pointer, drawn as a placeholder.
    var liftedSurfaceItem: String? {
        get { self[LiftedSurfaceItemKey.self] }
        set { self[LiftedSurfaceItemKey.self] = newValue }
    }

    var studioPageOverride: StudioPageOverride? {
        get { self[StudioPageOverrideKey.self] }
        set { self[StudioPageOverrideKey.self] = newValue }
    }

    var studioMiniOrderOverride: StudioMiniOrderOverride? {
        get { self[StudioMiniOrderOverrideKey.self] }
        set { self[StudioMiniOrderOverrideKey.self] = newValue }
    }
}

extension View {
    /// Marks one arrangeable thing on a surface — a page card, a mini-window
    /// cell — by the identity the arrangement stores it under.
    ///
    /// Apply it at the render site of anything a user can drag in the Studio.
    /// A card or cell without the tag still draws, but the Studio cannot pick
    /// it up.
    func surfaceItem(_ id: String) -> some View {
        modifier(SurfaceItemModifier(id: id))
    }
}

private struct SurfaceItemModifier: ViewModifier {
    let id: String

    @Environment(\.surfaceItemFrames) private var frames
    @Environment(\.liftedSurfaceItem) private var lifted

    @ViewBuilder
    func body(content: Content) -> some View {
        if let frames {
            content
                // The placeholder: still in layout so the others make room
                // around it, faded so the picture under the pointer is
                // unmistakably the thing being moved.
                .opacity(lifted == id ? 0.22 : 1)
                .animation(.easeOut(duration: 0.18), value: lifted == id)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(SurfaceCoordinates.space))
                } action: { frame in
                    frames.report(frame, for: id)
                }
                .onDisappear { frames.forget(id) }
        } else {
            content
        }
    }
}
